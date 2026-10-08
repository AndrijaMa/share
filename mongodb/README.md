# OpenFlow Connector property refresh via Github Actions 

## Prerequisites

Before you begin, you will need:

- A GitHub account
- Access to a Snowflake account
- A Snowflake service user (`SVC_OPENFLOW`)

## 1. Fork the GitHub Repository

Create a fork of the following repository:

https://github.com/AndrijaMa/auto2

Fork the repository into your own GitHub account or organization.

Once the fork has been created, work from your fork for the remaining setup steps.

## 2. Generate a GitHub Personal Access Token

You need to create a **Fine-grained Personal Access Token (PAT)** that will be used by the Openflow service user.

In GitHub, navigate to:

**Settings → Developer settings → Personal access tokens → Fine-grained tokens**

Create a new token with the following permissions:

| Permission | Access |
|---|---|
| Metadata | Read |
| Issues | Read and Write |

Generate the token and **copy the PAT value immediately**. You will use this value when configuring `OPENFLOW_PAT`.

> **Important:** Treat the PAT as a secret. Do not commit it to GitHub or include it directly in source code.

## 3. Configure GitHub Actions Secrets and Variables

In your forked repository, go to:

**Settings → Secrets and variables → Actions**

### Create the following secret

Create a repository secret named:

`OPENFLOW_PAT`

Set the value to the PAT you generated for your `SVC_OPENFLOW` user.

### Create the following variables

Create these three repository variables:

| Variable | Value |
|---|---|
| `OPENFLOW_ACCOUNT` | Your Snowflake account identifier |
| `OPENFLOW_INGRESS_PREFIX` | `of2` |
| `OPENFLOW_RUNTIME_KEY` | The name of your Snowflake Openflow runtime |

The configuration should therefore contain:

**Secret**

```text
OPENFLOW_PAT = <your GitHub PAT>
```

**Variables**

```text
OPENFLOW_ACCOUNT = <your Snowflake account identifier>
OPENFLOW_INGRESS_PREFIX = of2
OPENFLOW_RUNTIME_KEY = <your Openflow runtime name>
```

## 4. Update the GitHub Repository Reference

The code contains a reference to the GitHub API endpoint:

```text
https://api.github.com/repos/AndrijaMa/automations/issues
```

Search the repository for:

```text
https://api.github.com/repos/AndrijaMa/automations/issues
```

Replace:

```text
AndrijaMa/automations
```

with:

```text
<your-github-username>/<your-repository-name>
```

For example, if your GitHub username is `johnsmith` and your repository is called `automations`, the URL should become:

```text
https://api.github.com/repos/johnsmith/automations/issues
```

Make sure you update **all occurrences** of the original repository reference.

## 5. Review the MongoDB Connection String

Review the following setting in the code:

```text
conn_string := ''mongodb://'' || :host_list
```

Verify that the resulting MongoDB connection string is correct for your environment.

Pay particular attention to:

- MongoDB hostnames
- Port numbers
- Replica set configuration, if applicable
- Authentication requirements
- TLS/SSL requirements
- Any additional MongoDB connection parameters

Do not commit usernames, passwords, or other credentials directly into the repository.

## 6. One-Time Manual Configuration of the MongoDB Parameter

This step requires a **one-time manual intervention** in the Openflow runtime.

### 6.1 Fetch the parameters

In your Openflow runtime:

1. Go to your **Runtime**.
2. In the **top-right corner**, select **Controller Settings**.
3. Select **Parameter Providers**.
4. Find the appropriate parameter provider and select the **three vertical dots** on the right.
5. Select **Fetch parameters**.

The **Fetch Parameter** window will open.

### 6.2 Select the MongoDB parameter

In the Fetch Parameter window:

1. On the left-hand side, select the appropriate **Parameter Group Name**.
2. Select the path where you stored your **MongoDB Secret** containing the parameter.
3. Select the checkbox **Create parameter context**.
4. **Uncheck** the checkbox next to the value `MONGODB`.
5. Select **Apply**.

This will create the parameter context and make the MongoDB parameter available to the runtime.

### 6.3 Configure the MongoDB Connector

Next, configure the MongoDB Connector to use the newly created parameter.

In your Openflow runtime:

1. Locate your **Mongo DB Connector**.
2. Right-click the connector.
3. Select **Parameters**.
4. Locate **MongoDB Connection URI**.
5. Set the value to:

```text
#{MONGODB}
```
6. Apply the configuration.
7. Go to the runtime where your MongoDB Connector is Right click on the MongoDB Processor group Select.
8. Select Inheritance.
9. Drag the Parameter contexts that you previously Enabled from the left to the right side and make sure that it is on the top.
The MongoDB Connector will now use the `MONGODB` parameter value rather than having the connection URI configured directly in the connector.

> **Note:** This manual configuration is only required once when setting up the runtime.

## 7. Final Configuration Checklist

Before running the solution, verify that:

- [ ] You have a GitHub account
- [ ] You created a fork of `auto2`
- [ ] You generated a Fine-grained GitHub PAT
- [ ] PAT has **Metadata → Read** permission
- [ ] PAT has **Issues → Read and Write** permission
- [ ] `OPENFLOW_PAT` has been created as a GitHub Actions secret
- [ ] `OPENFLOW_ACCOUNT` has been configured
- [ ] `OPENFLOW_INGRESS_PREFIX` is set to `of2`
- [ ] `OPENFLOW_RUNTIME_KEY` contains your Openflow runtime name
- [ ] All references to `AndrijaMa/automations` have been changed to your GitHub repository
- [ ] The `conn_string` MongoDB configuration has been reviewed
- [ ] The MongoDB parameter has been fetched into the Openflow runtime
- [ ] **Create parameter context** was selected
- [ ] The `MONGODB` value was unchecked during parameter fetching
- [ ] The MongoDB Connector uses `#{MONGODB}` as its **MongoDB Connection URI**
- [ ] No credentials or PATs have been committed to the repository


Once these steps are complete, the repository is ready for the Openflow setup and execution.
