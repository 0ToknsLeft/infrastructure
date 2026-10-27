# Infrastructure

Runs the [todo app](https://github.com/0toknsleft/todo-app) on AWS
(in the region of your AWS profile, or `eu-central-1` if it has none): an EC2
instance serving HTTP on port 80, an RDS SQL Server Express database in private
subnets, and the app's logs in CloudWatch (`/todoapp/app`). Set `AWS_REGION` to
use another region.

Run `make` to list the available commands.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) 1.16 or newer
- AWS CLI with credentials for the account
- Docker, `jq`, `ssh`, [uv](https://docs.astral.sh/uv/) and GNU make

Then run `make setup` once to create the state bucket and initialise
terraform. It prints the account, region and app version it works with, and
asks before creating the bucket. Nothing in the repository names an AWS
account: the targets act on whichever account your AWS credentials belong to.
Run `make setup` again after switching accounts.

## Secrets

No secrets are kept in git. They live in the state bucket or in the terraform
state, so anyone who can read the bucket can read them.

- `secrets/dataprotection.pfx` and its password are the app's ASP.NET Core
  data protection certificate. They are kept in the state bucket under the
  same paths. `make deploy-app` downloads them, or generates and uploads them
  when the bucket has none. The local copies are ignored by git and removed by
  `make clean`.
- `ssh_key.pem` is the SSH key shared by all instances. It is written from the
  terraform state on demand, ignored by git, and removed by `make clean`.

## Terraform

There are two root modules:

- `tf/infra` holds the VPC, the app instance (tagged `Role=app`, shipping its
  journal to CloudWatch with Fluent Bit), the RDS instance, security groups
  and the SSH key pair.
- `tf/db` holds the app's login (`todo_app_user`) and database (`TodoAppDB`)
  inside SQL Server. It reads the `tf/infra` state and reaches the server
  through the [database tunnel](#connecting-to-the-database).

`make infra-plan` shows pending changes and `make infrastructure` applies both
modules. Targets that depend on the state, such as `deploy-app`, `migrate` and
`db-tunnel`, apply changed `.tf` files first.

The state of both modules lives in the S3 bucket
`0toks-infrastructure-<account-id>-<region>`, which `make setup` creates with
versioning enabled. Terraform locks it while applying, so several people can
work against the same account.

## Deploying the app

1. Set `APP_VERSION` in the `Makefile` to the todo-app release to deploy. It
   picks both the image `ghcr.io/0toknsleft/todo-app:<version>` and the deploy
   tooling at tag `v<version>`.
2. `make migrate` runs the image's `migrate` command against the database.
3. `make deploy-app` deploys to every running instance tagged `Role=app`. It
   uses the `setup-webapp` tool from the todo-app repository's `deploy/`
   directory, which configures the instances with Ansible over SSH and hands
   them the connection string and data protection certificate.
4. Commit the `Makefile`, e.g. as `Deploy v<version>`.

`make setup-tls host=<instance-id> domain=<domain> [email=<address>]` gets a
Let's Encrypt certificate for the domain and serves the app over HTTPS on that
instance, with the `setup-tls` tool. Point the domain at the instance and deploy
the app first.

`make ssh host=<instance-id>` opens a shell on an instance. The instance ids
are listed by `make infra-state name=ec2_instances`. `make infra-state` lists
the terraform outputs of both modules, hiding the sensitive ones, and
`make infra-state name=<output>` shows the value of one, sensitive or not.

## Connecting to the database

The database lives in private subnets and is only reachable from inside the
VPC. `make db-tunnel` launches a temporary EC2 instance, forwards `127.0.0.1:1433`
to the database through it and prints the connection details. Press Ctrl-C to
close the tunnel; the instance is terminated. `make migrate` and the `tf/db`
targets use the same tunnel on their own.

Local port 1433 must be free, so stop a local `todoapp-db` container first.

In DBeaver, create a SQL Server connection and either paste the printed JDBC
URL into the URL field, or fill in host, port, database and user and enable
"Trust server certificate". The tunnel prints the command that shows the
password.

## Tearing down

`make destroy` destroys everything in `tf/infra`, including the database
(without a final snapshot, so its data is lost), and deletes both state files
from the bucket.
