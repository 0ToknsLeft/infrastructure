# Infrastructure

Run `make` to list the available commands.

## Connecting to the database

`make db-tunnel` launches a temporary EC2 instance, forwards `127.0.0.1:1433`
to the database through it and prints the connection details. Press Ctrl-C to
close the tunnel; the instance is terminated.

Before the first run:

- run `make setup` to unlock the secrets and initialise terraform
- have AWS credentials for the account configured
- free local port 1433, e.g. stop a local `todoapp-db` container

In DBeaver, create a SQL Server connection and either paste the printed JDBC
URL into the URL field, or fill in host, port, database and user and enable
"Trust server certificate". The tunnel prints the command that shows the
password.
