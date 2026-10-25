# Infrastructure

Runs the [todo app](https://github.com/0toknsleft/todo-app) on AWS
(`eu-central-1`): an EC2 instance serving HTTP on port 80, an RDS SQL Server
Express database in private subnets, and the app's logs in CloudWatch
(`/todoapp/app`).

Run `make` to list the available commands.

## Prerequisites

- [git-crypt](https://github.com/AGWA/git-crypt) and a GPG key that has been
  added to this repository
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.16 or newer
- AWS CLI with credentials for the account
- Docker, `jq`, `ssh`, [uv](https://docs.astral.sh/uv/) and GNU make

Then run `make setup` once to unlock the secrets and initialise terraform.

## Secrets

git-crypt encrypts the terraform state (`tf/*/terraform.tfstate`) and
`secrets/`, see `.gitattributes`. Access is per GPG key: someone who already
has access runs `git-crypt add-gpg-user <key-id>` and commits the result.
Until the repository is unlocked the state files are unreadable and every
target fails.

- `secrets/dataprotection.pfx` and its password are the app's ASP.NET Core
  data protection certificate. `make deploy-app` generates them if missing.
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

The state is local and committed to git, with no locking. Pull before applying,
let only one person apply at a time, and commit the updated state files right
after.

## Deploying the app

1. Set `APP_VERSION` in the `Makefile` to the todo-app release to deploy. It
   picks both the image `ghcr.io/0toknsleft/todo-app:<version>` and the deploy
   tooling at tag `v<version>`.
2. `make migrate` runs the image's `migrate` command against the database.
3. `make deploy-app` deploys to every running instance tagged `Role=app`. It
   uses the `setup-webapp` tool from the todo-app repository's `deploy/`
   directory, which configures the instances with Ansible over SSH and hands
   them the connection string and data protection certificate.
4. Commit the `Makefile` and the state files, e.g. as `Deploy v<version>`.

`make ssh host=<instance-id>` opens a shell on an instance. The instance ids
are listed by `terraform -chdir=tf/infra output ec2_instances`.

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
(without a final snapshot, so its data is lost), and deletes both local state
files.
