# Detailed Documentation

#### links to related docs

- [Invitation to Play](./1_0_invite.md)
- [Unyt Setup](./README.md)
- [Detailed Documentation](./5_0_phase_5_testing_details.md)
- [Unyt Dictionary](./4_2_unyt-dictionary.md)
- [Intro to Smart Agreements (Three Layers)](./4_1_intro_to_smart_agreements.md)
- [Templates and Smart Agreements Library Repo](https://github.com/unytco/smart_agreement_library)
- [Feedback](https://github.com/orgs/unytco/projects/5/views/1)


**WARNING: This doc contains details!**

Feel free to use the outline view available in the upper right to get an overview of the different content covered.

## Orientation

### Overview of context

Unyt is decentralized software that lets communities create and run their own credit and payments systems.

At present, our team is primarily focused on supporting Decentralized Physical Infrastructure Networks (DePIN) with transaction processing designed to handle high volumes of activity with very low costs.

Unyt Features:

* Lightweight (can run on ordinary consumer devices)
* Low Cost (cheap)
* Support for Microtransactions (economically viable even for transactions worth pennies)
* Can support Parallel Transaction Processing (fast and high volume)
* Customizable Smart Agreements (an agent-centric alternative to blockchain style smart contracts)
* Complements a project's existing blockchain token(s) and can be used alongside them.
* Enables delegation of a project's compliance with financial regulations (Crypto / Anti Money Laundering / Know Your Customer) freeing teams to focus on their core value proposition.

For Testing purposes, all testers will be participating in the same Unyt Accounting Alliance, which uses ZF as its Base Unit/Fuel Credit. As a result, all testers are joining a single peer network and will be able to send and receive credits from anyone else in the test network as well as see and interact with any of the smart agreements that other testers create.

Since this is a shared application and social space, any Code Template, Smart Agreement or Record of Agreement Verifiably Executed (RAVE) that you create will be visible to other testers.

Unyt is being built by a small, focused team, several of whom helped found 1) Holochain, the framework for building peer-to-peer applications that powers Unyt's ability run as a decentralized application as well as 2) Holo Hosting, a decentralized cloud application hosting service.

### A Request

As you test Unyt, please try to imagine new ways that you and your team might be able to use this to help recognize real contributions and foster more of them.

If you would like to run something by us, feel free to reach out via whatever channel your team is already in communication with us including the Unyt channel in the [DEV.HC Discord](https://discord.com/invite/k55DS5dmPH) or simply by sending an email to:

info@unyt.co

### Version

In Phase 5, we are testing version 0.40.0 of Unyt.

### Reminders

1) This version of the software hasn't had its UX/UI refined for a particular use case or for a particular set of end users.

2) This version is intended to help community members, partners and their developers gain familiarity with the features and functionality of Unyt, and

3) We want to help the community begin exploring the ways in which they may want to make use of Unyt for their use cases.

### Priorities for Phase 5

1) We are seeking feedback on overall features and functionality and

2) We want to support you in designing, creating and testing your own Smart Agreements that deliver on the business logic relevant for your context.

## Overview of what is NEW in Phase 5

The biggest changes since Phase 4 testing are:

1) Using a mix of Zero Arc nodes and Full Arc nodes. Full Arc nodes have responsibility for validating, storing and serving all content. Zero Arc nodes are responsible for no content. Later releases will include Partial Arc nodes. 
2) Making use of Tx5 as a networking layer. We've played around with a couple of networking layers including the Holochain team's very own Tx5 as well as an independent networking stack called IROH. Our most recent round of testing saw Tx5 working better and so we are going to focus on Tx5 for the time being.

## Table of Contents

INTRODUCTION

UNYT DICTIONARY

BUILD DETAILS
- Copy Build ID (DNA Hash)

NETWORK STATUS
- Network Status
- Connection Type
- Connection Overview
- Peer Details

AGENT MODAL
- Base Unit Balance
- Identicon
- Open Menu
  - Agent Overview
  - Your Address
  - Your Name
  - Address Book Contacts
  - Credit Limit
  - Unit Balance(s)
  - A Note on Fees

HOME

- Send Units
  - Amount
  - Unit
  - Add Another Credit
  - Select a Contact
  - Notes
  - Add to Watched Items
  - Cancel
  - Send

- Request Units
  - Amount
  - Unit
  - Add Another Credit
  - Select a Contact
  - Notes
  - Add to Watched Items
  - Cancel
  - Request

- Action List
  - Interaction
  - Amounts
  - Your Role
  - Parties
  - Date
  - Actions

- Watched List
  - Interaction
  - Status
  - Unwatch

- Recent History
  - Interaction
  - Amounts
  - Your Role
  - Parties
  - Date
  - View

History

- Interaction History Browser

DEV MODE

- BUILD

  - Create New Template
  - Create Agreement
  - Folders
    - Public
    - Your Local Drafts
    - Private
    - System


LIBRARY

- How to Create a Smart Agreement
- Add Agreement Code Template
  - Title
  - Input Schema
  - Execution Code
  - Output Schema
- Create a Smart Agreement from an Agreement Code Template
  - Title
  - Execution Rules
    - One Time Run (toggle on / off)
    - Aggregate Execution (toggle on / off)
    - Who can Execute?
      - Anyone
      - Authorized Executor
  - Roles
    - Role Name
    - Description
    - Qualification Type
      - Any
      - Authorized
      - KYC
  - Input Rules
    - Provided by Role
      - Select Role
    - Executor Provided
    - Fixed
    - Query
    - Custom (Preset Query)
- Examples and Guidance for Creating Custom Smart Agreements
- Viewing Smart Agreements
- Interacting with a Smart Agreement, including as an Executor

DATA RECORDS

- Creating New Data Records
  - Create a Conversion Table
  - Create a Recipe
  - Create a Code Sheet
  - Add New Data Record (Custom)

- Data Records Table
  - View Data Records

ADMIN
- Global
  - Global Configuration
    - Global Config Window
      - Effective Start Date
      - Expiration Date
    - System Agreements
      - Compute Credit Limit Agreement
      - Compute Transaction Fee Agreement
      - Fee Trigger
      - Fee Percentage
    - Additional Information
      - Additional Special Agents
      - Global Configuration declared Smart Agreements
  - Units
    - Base Units
    - Service Units
  - Service Networks
    - Initialize Service Network
      - Service Network Config
        - Basic Properties
          - Name
          - Abbreviation
          - URL
          - Outside Currency Name
          - Outside Currency Symbol
          - Service Network Admnistrators
        - Service Network Config Window (Previously "Lane Definition". UI update in progress)
          - Effective Start Date
          - Expiration Date
        - Special Agents
          - Ops Account
          - Service Infrastructure Account
          - Bridge Agent
        - Smart Agreements
          - Purchase of Units
          - Redemption of Units
          - Proof of Service
    - View Service Network Config
    - Service Network Console

NETWORKS
  - Smart Agreements
    - Purchase of Fuel Credits
    - Redemption of Fuel Credits
    - Proof of Service
  - Add Conversion Sheet
  - Drop off Proof of Deposit
  - Redemption Agent Redeems
  - Current Redemption Rate

## INTRODUCTION

Unyt is decentralized software that lets communities create and run their own credit and payments systems. Unyt can account for payments and for services provided in accordance with smart agreements custom designed to meet your community's needs.

Each Unyt Application is built using Holochain, which is a free, open-source framework for creating apps that run in a decentralized manner.

There is no global Unyt application. Each community runs their own version of Unyt, customized to meet their needs. We refer to each of these groups as a Unyt Accounting Alliance (or Unyt Alliance) and each App as a Unyt Accounting Alliance Application (or Unyt App).  

Each Unyt App is run by the members of that particular Unyt Alliance and its members enforce the rules that their community has opted to create and use.

Each Alliance App has its own name, its own payment unit of account (Base Unit or Fuel Credit), its own Service Units (optional) and its own sets of smart agreements that are used and enforced -- all in a decentralized manner.

Each Alliance also chooses its own rules governing Credit Limits. A Credit Limit determines how far into the negative a particular agent is allowed to spend in a particular Unit.

An Alliance can include one or more Service Networks, essentially sub-communities with their own sets of Smart Agreements and Service Units that are relevant to the particular kinds of services being offered within that subcommunity. For example, Holo Hosting might be a Service Network in a larger Decentralized Physical Infrastructure Unyt Alliance.

Finally, each Alliance determines which external currencies (such as Service Network related blockchain tokens) can be used to purchase the Base Units of that Alliance and the methods by which such purchases can be made as well as any requirements that need to be met for an agent to be eligible to redeem Base Units for a specific external currency.

Next lets walk through the different components of a Unyt application, one component at a time.

## Setup and Login
Peers start by installing a Unyt Alliance app on their computer and then going through setup.

See the [README](../README.md) section of the Unyt Releases Repository for Installation and Set up instructions.

At present, this may involve giving the application permissions to run on your machine. See [Setup](../README.md#setup) for details.

After setting up Unyt, you may get a notification that it has not yet synced. This should not take long, assuming at least one other user of the app is online that has synced with the progenitor that set up this app version. That progenitor has added some Smart Agreements to set some initial groundrules (including a system_credit_limit_computation) that we are going to be using. They (and maybe others) have added other Smart Agreements as well that we can try out. Once you are synced, you will have a credit limit available and will be able to spend into the negative up to your credit limit.

### Let's test together

Feel free to try out some transactions. If you don't have anyone else to test alongside, you can Send Credits to, or Request Credits from Matt Schutte with a Spend or an Invoice.

Matt's public key is:

```
uhCAkMw40nAwQPlNegqSbiG1lqTSRB87TWDCuQvwr0dSPP5QAPXu9
```

And feel free to reach out to us through our shared comms channel on Telegram or Signal or via email at info@unyt.co

We are more than happy to jump on a video conference call to test alongside you for a bit.

UNYT DICTIONARY
Check out the [Unyt Dictionary](./4_2_unyt-dictionary.md) for a glossary of terms.

Let's get into the App details!

##  UNYT APP DOCUMENTATION

### BUILD DETAILS
On the bottom left of the App, you should see some Build Details. These include the Name and Version Number of the Application as well as a shortened version of the Build ID, a unique id for the version of the app you are running. 

#### Copy Build ID (DNA Hash)
Click to copy the Build ID. That string of characters allows you to check that you are running an identical version of the application as someone else. If both of your Build IDs match, you are running the same version and should be able to transact with one another.

### NETWORK STATUS
#### Network Status
On the bottom right of the App is the Network Status.
When disconnected from other application peers, status is "Connecting"
When connection to peers is established, status is "Connected"

Clicking on the Connection Status will display details about your communication with peers that are running the Application.

#### Connection Type
Displays the type of Networking Protocol being used to communicate with Application Peers.

#### Connection Overview
Displays information about your communication with other App Peers.

- Active Peers shows the number of peers that you currently have an open connection with.

- Total Sent shows the total amount of data that has been sent to other Active Peers.

- Total Received shows the total amount of data that has been received from Active Peers.

- Total messages shows a count of the number of messages sent and receieved from the connections you currently have open. These messages mostly consist of backend communications involved in validating, storing and syncronizing data. You may have only sent a couple of transactions, or even none, but your instance of the application is running and is participating in the operation of the app and so you may already see hundreds of messages being passed back and forth as part of that operation.

#### Peer Details
Peer Details shows details for each Active Peer, including a User ID (which is not the same as that user's Agent ID), total data sent, total data received, number of messages communicated and most recent interaction with each peer that you have interacted with. 



## AGENT MODAL
On the upper right, you will see the Agent Modal. Initially just your Base Unit Balance and Identicon are displayed

### Base Unit Balance

##### Base Unit

We refer to the main payment units in a Unyt Accounting Alliance as Base Units. 

Your Base Unit Balance shows the present balance of your account. 

Your balance starts at Zero and will reflect the total number of Base Units that you have accepted from other agents minus those you have spent (including those set aside for payment of service and transaction fees). You can spend into the negative up to your credit limit.

In this particular Unyt App, we are using Z Fuel as the name and ZF as the symbol for the Base Units. Once your device syncs with other peers, you should see this change from "0 Z" to "0 ZF". This is one indicator that you have synced with other peers.

### Identicon
Next to your balance is a colorful circle. This is what we refer to as an "identicon." It is an image that is generated based on your Agent Address in the app.

The intent with identicons is to give people an easy way to recognize that a particular Agent Address might not be the same as it usually is. People are better at recognizing that a picture looks different than they are at seeing a long string of characters and assessing whether or not there might be one or more characters that have been altered.

Clicking on the Balance or the Identicon will open up your Agent Overview Sidebar

### Agent Overview
#### Agent Settings
Clicking on the Gear Icon next to Agent Overview will open up your Agent Settings. This modal displays some app and version details as well as an ability to enable yourself to use the application as a Service Network Admin, or to run the app in Dev Build Mode.

Service Network Admins are able to Design New Service Networks. Dev Build Mode lets you create, view, edit and publish Smart Agreements and Code Templates. Most Unyt Apps wouldn't have these admin roles open to everyone, but we want you to see how this stuff actually works and to be able to try creating some Code Templates, Smart Agreements and Service Networks of your own.

#### Your Address
Unyt makes use of public/private key cryptography to enable participants to enable you to choose to show up in the Unyt Alliance as the same actor (agent) over and over again. Though technically your public key, you can think of it simply as your Address.

Click the copy icon next to "Your Address" to copy your Address to your clipboard. Then paste it into other areas of this Unyt application to interact with Smart Agreements or perform direct transactions. You can also share it directly with other people through whatever medium you wish, whether via email, signal, telegram, singing telegram or smoke signal.

They will enter it on their own copy of this Unyt App when doing things like sending you a payment or a payment request or when granting you authorization to interact with a Smart Agreement through a particular Role.


#### Your Name
This is just for your own ease of use. Fill in your name here, and that will be displayed instead of your Address in various parts of the app.

#### Address Book Contacts

This is a local address book. You are the only one who will see the nicknames and notes that you associate with different Agent Addresses. If you add a contact to your Address Book, whatever name you gave that Agent will show up instead of their raw Address when doing things like sending, receiving or reviewing past transactions.

#### Credit Limit

Your Credit Limit is the amount below zero (in the Base Unit) that you can spend to in accordance with the applications rules.

This section displays the credit limit that was returned after the last time your software checked your Base Unit Credit Limit. If you have just downloaded the app, or have never tried to spend into the negative, then your credit limit will never have been checked, and you will likely see a credit limit of "0".

A simple credit algorithm that actually increases your credit limit by 10 units every time you spend is being used in the current app. Other simple versions include a fixed credit limit, say of 10,000 units. More complicated versions can take into account your history as service provider, basing your credit limit on the credibility that you have established within the community. 

Your Unyt Alliance can also define additional credit limit algorithms for other Units, with custom designed credit limit algorithms for different Service Units, for example. 

#### Unit Balance(s)

This is list of balances for any units that you have interacted with. By default, the Base Unit (main payment unit) is at the top. Other Service Units (if you have Sent or Accepted any) will be below.

#### A Note on Fees

The members of a particular Unyt Alliance can structure that application to charge Transaction Fees when Base Units are spent.

In this test version, a Transaction Fee of 0% is being used. If there was a Transaction Fee, it would be owed when an agent spends Base Units by sending them to an agent directly or by sending them to a Smart Agreement.

Any Transaction Fees that are owed -- but have not yet been paid -- are set aside (earmarked) and will be paid once some accumulation threshold is met.

That Fee Payment threshhold is set by each Unyt Alliance.

If a send transaction would result in that threshold being crossed, that transaction will be preceded by the sending (payment) of fees owed.



## HOME

### SEND UNITS

Click the Send Units button near the upper right to send Units directly to another agent. 

#### Amount

In the Amount section, enter the number of Units that you want to send.

#### Unit
Select the type of Unit to send. The Base Unit is selected by default. 

#### Add Another Credit
Click to add a different kind of Unit (Note that this only works if the app has more than one kind of Unit available to send).

#### Select a Contact
Either enter the Address of the agent to whom you are wanting to send the credits or select one from your list of contacts (which displays your Address Book Contacts).

#### Notes
You can also add a note. This is optional.

#### Add to Watched Items
If you add the transaction to Watched Items, it will show up in your Watched Items list. 

#### Cancel
Cancels the transaction and closes the modal.

#### Send 
As soon as you click "Send", your device will check for several potential issues with the transaction - including whether the Receivers Address is appropriately structured and whether the send (plus transaction fees) would bring your account balance beyond the credit limit available to you.

Assuming there are no such validation violations, the send will complete, your device will "sign" the transaction with your private key (which allows other devices to confirm that it was actually you trying to send some of your credits) and your account will be debited the amount of the transaction, plus transaction fees. 

In addition, your device will publish a notification that will alert the receiver that they have credits available to accept.

We will cover Accepting credits in the Action Table section below, but first lets cover Requests.

### REQUEST UNITS
Click the Request Units button near the upper right to Request Units directly from another agent. You can also think of this as sending an invoice to an agent.

#### Amount

In the Amount section, enter the number of Units that you want to request.

#### Unit
Select the type of Unit to request. The Base Unit is selected by default. 

#### Add Another Credit
Click to add a different kind of Unit (Note that this only works if the app has more than one kind of Unit available to request).

#### Select a Contact
Either enter the Address of the agent from whom you are requesting credits or select one from your list of contacts.

#### Notes
You can also add a note. This is optional.

#### Add to Watched Items
If you add the transaction to Watched Items, it will show up in your Watched Items list. This can be helpful, as it will allow you to see that the transaction is still pending action by the other party.

#### Cancel
Cancels the transaction and closes the modal.

#### Request
As soon as you click "Request", your device will check for several potential issues with the transaction - including whether you have filled out all required fields and whether the Address of the agent you are requesting units from is appropriately structured.

Assuming there are no such validation violations, the request will complete, your device will "sign" the request with your private key (which allows other devices to confirm that it was actually you trying to request some credits) and your device will publish a notification that will alert the other party that they have received a payment request. This will show up in their Action List.

### AGREEMENT ACTIONS
The Agreement Actions modal allows you to select an agreement and interact with it through any role for which you are authorized.

A note about Execution of Smart Agreements.

In Unyt, Direct Transactions are executed by just the Spender and the Receiver themselves through their individual actions. However, for more complicated transaction logic, Unyt supports Smart Agreements that make use of a particular party as the Executor. A Smart Agreement can be configured to support either anyone acting as the Executor, or only a specific party authorized to serve as the Executor.

When you click to interact as an Executor on a Smart Agreement, an Execute Agreement modal gets displayed. This modal will include the Executor Inputs that are required (if any), per the Smart Agreement as well as the option to Execute the Agreement, or simply close the modal.

At present, there is not an automatic check to make sure that all required parties have interacted with the Smart Agreement. If you attempt to Execute the agreement and not all conditions are satisfied, Execution should fail. You can try to execute again at a later date.

#### Interacting Through a Role

When you click to interact with a Smart Agreement through a particular Role, if there are Inputs that are to be contributed from that Role, you will be presented with the relevant fields where you can enter the data for each of those inputs.

After all required fields are filled out (and any optional ones you choose to fill), click Create to publish the interaction with the Smart Agreement.

This will publish your action on your own Source Chain and will also publish one or more links to the Smart Agreement that are used as indicators that others can find regarding your actions and their consequences. 

For more background on Smart Agreements, see [Intro to Smart Agreements (Three Layers)](./4_1_intro_to_smart_agreements.md).

### ACTION LIST

This is where you can view in-process transactions that are ready for you to act on (Actionable) 

Let's review the different columns in the Action List.

#### Interaction
##### Crypticon
An icon generated from the content of the previous action in that interaction. Clicking on the Crypticon will copy the action id to your clipboard.

##### Label and Description
These provide a bit of context about the kind of action that you are being invited to take in this interaction.

##### AMOUNTS

The quantity and type of each unit involved in the transaction. 

##### YOUR ROLE
The name of your role in this interaction, whether that is as a spender, a receiver, an executor or some particular role for interacting with a smart agreement.

##### PARTIES
The other parties that are involved in this interaction. Clicking on their Identicon will copy their public key to your clipboard.

##### DATE
The date and time of the most recent action.

##### ACTIONS
Clicking on the check mark will confirm an interaction, whether a spend, an accept, or something else.

Clicking on the "x" will reject the interaction. It will not show up in your history, as it was an item that you chose not to confirm.

Clicking the magnifying glass icon (or anywhere in the white space of the row) will open the view modal for the transaction, where you will be able to see the details and confirm or reject.  

Once you have confirmed a send or a request payment interaction, the transaction will be moved to the History table (and if recent, will be included in the Recent History as well). A transaction with a status of "Completed" indicates that there are no additional actions for you to take. This is true even if one or more other agents still have other actions to take, such as accepting units. If you have already "spent" the units, from your perspective the transaction is complete. The units have been debited from your account. This is true regardless of whether or not the receiver has accepted them yet. This is one of the unusual characteristics of Unyt's agent-centric accounting system.

### WATCHED LIST
#### Interaction

##### Crypticon
An icon generated from the content of the previous action in that interaction. Clicking on the Crypticon will copy the action id to your clipboard.

##### Label and Description
These provide a bit of context about this interaction, including a Crypticon, Label, Description and the date of the most recent interaction.

#### Status
Indicates either that the status is completed or if incomplete, which parties are yet to take action. Click to copy a parties address to the clipboard.

#### Unwatch
Removes the interaction from the watched list.

### RECENT HISTORY
Recent History displays transactions where you have a completed action, whether that involves a credit check, a spend, an accept, or an interaction with a Smart Agreement.

Most columns are similar to their counterparts in the Action List. Each row displays some action that you have taken that is complete, regardless of whether others still may have actions of their own to take.

#### Interaction
##### Crypticon
An icon generated from the content of the action that you completed. Clicking on the Crypticon will copy the action id to your clipboard.

##### Label and Description
These provide a bit of context about the kind of action that you took in this interaction.

#### AMOUNTS

The quantity and type of each unit involved in the transaction. 

#### YOUR ROLE
The name of your role in this interaction, whether that was as a spender, a receiver, an executor or some particular role for interacting with a smart agreement.

#### PARTIES
The other parties that were involved in this interaction. Clicking on their Identicon will copy their public key to your clipboard.

#### DATE
The date and time of the action.

#### VIEW

Clicking the magnifying glass icon (or anywhere in the white space of the row) will open the view modal for the transaction, where you will be able to see the details.  

## HISTORY

### Interaction History Browser

Same content as Recent History, but contains a log of all completed Actions and not just the most recent ones.

### Export CSV

There are two types of reports that can be downloaded as .csv files: Detailed History and Smart Agreement Interactions

#### Detailed History

Download direct interactions including any units sent, units accepted and fees, as well as the resulting balance.

#### Smart Agreement Interactions

Download interactions with Smart Agreements, including:

##### Parked 
Content that has been attached to an agreement 

##### ParkedSpend
Units that have been attached (sent) to an agreement 

##### RAVE (or SAVED)
Records of Agreements that have been Verifiably Executed (RAVEs). These have at times been called Smart Agreement Verifiable Execution Documents (SAVEDs)

##### Accept 
Units that have been accepted after being allocated through the execution of an agreement.

## BUILD

The Build section is where participants that have Dev Build Mode access can view, create and edit Smart Agreements. Some agreements, such as those governing Credit Limits or Transaction Fees require authorization in order to make edits. 

For an introduction, see [Intro to Smart Agreements (Three Layers)](./4_1_intro_to_smart_agreements.md)

Assuming you have read through that, or already have an idea of what Smart Agreements are, lets explore a bit more about how they are made.

### How to Create a Smart Agreement

The creation of a Smart Agreement involves a few steps:

First, you need to create an Agreement Code Template (or "Agreement Template" or simply "Template" for short). This will provide the core logic of your Smart Agreement.

Once an Agreement Code Template has been created, a number of different Smart Agreements can make use of that Template but each can be configured differently, whether that involves different sources for inputs, different roles created and authorized to take particular actions, or authorizing different agents to perform some particular action.

In other words, Agreement Code Templates make it easy to re-use the core logic in multiple contexts, which supports both clarity about which particular ruleset is being made use of in a specific context, as well as community learning with regard to which patterns work well, and where.

Lets now dive into the details of the three main elements of the Build Panel:

- Adding an Agreement Code Template,
- Creating a Smart Agreement, and
- Copying, Editing and Publishing from existing Code Templates and Smart Agreements

### Create New Template

If you click the "Create New Template" button near the upper right of the Build Panel screen, it will bring up the Create  Code Template screen.

An Agreement Code Template enables a particular set of basic rules to be re-used by multiple Smart Agreements. Those rules include:

#### Template Title
Give your template a title

#### Runtime Input Signature 
The required structure of the inputs, or input schema

#### Execution Code
The core logic of how those inputs will be transformed to create outputs

#### Output Signature
The required structure of the outputs, or output schema.

#### One Time Run

Certain agreements should be only executed (run) once. Other agreements are intended to be executed repeatedly.

To create a Code Template where a Smart Agreement based on that template can be Executed only once, toggle One Time Run on.

To create a Code Template where a Smart Agreement based on that can be Executed multiple times, toggle One Time Run off. 

On a Multi-Run Agreement, the Executor will gather the inputs that are available at the time of execution. Note that inputs that have been processed in a prior execution would no longer be available, though outputs from a prior execution (in the RAVE/SAVED that documents that execution) might be available as an input for a subsequent execution. That could be useful for carrying over unused balances, for instance.

#### Aggregate Execution

Aggregate Execution enables the Executor to gather multiple Inputs that have been parked on the Smart Agreement and process them all as part of a single Execution. This supports bulk processing of inputs.

#### Agreement Definition

This is a JSON schema that defines the inputs required for creating a smart agreement. UIs can use this to dynamically render forms for creating and configuring agreements. The schema should be a JSON object with a properties field.

This struct wraps a JSON schema (serde_json::Value) that defines the inputs required for a smart agreement. It is intended to be used by UIs to dynamically render forms for creating and configuring agreements. The schema should be a JSON object with a properties field.

For inspiration and more details, check out additional guidance and other Templates in the Public Folder within Unyt or view examples in the [Smart Agreement Library](https://github.com/unytco/smart_agreement_library)

You can save drafts of templates and can publish privately or publicly.

Once an Agreement Code Template has been created by any agent (with dev build privileges) in the Unyt Alliance, publishing it publicly will make it visible to other agents with Dev Build Privileges and will make it available to everyone running the software to interact with through the Agreement Actions modal on the Home screen. 

### Create Agreement
Smart Agreements always start from a Code Template.

A Smart Agreement is a specific implementation of a code template with additional definitions of:

- a Title,
- Execution Rules, including who is authorized to serve as Executor of this specific Smart Agreement,
- Roles, and
- the required source of each Input.

You can select an existing Code Template that you want to use. If you want to create a custom Code Template, publish that (privately or publicly) first. Then select it as the Code Template that you will build your Smart Agreement upon. That will pull in all of the components defined in that Code Template.

We'll go through each of the items in the Create Smart Agreement Modal, one-by-one.

#### AGREEMENT TITLE

Give this particular Smart Agreement a human readable Title for easy reference and differentiation from others.

#### WHO CAN EXECUTE THIS AGREEMENT

There are two options regarding who can Execute a Smart Agreement: Anyone or only an Authorized Executor.

1) Anyone

Any agent can execute the agreement.

An example:
Under the __system_credit_limit_computation Template, you can find the "credit check v0.1.0" Smart Agreement. This is an agreement that any agent can execute. 

Anytime an agent attempts to spend into the negative, Unyt first has your agent automatically execute this credit check v0.1.0 agreement, which creates an output with your agent's credit limit and publishes that to your source chain. If the send transaction you are attempting will not result in your Base Unit Balance going below its credit limit, the transaction will proceed. This also makes it easy for others to later validate what your credit limit was just prior to your attempted spend. It is always provided by the prior action, which they can independently verify was validly executed.

2) Authorized Executor

The alternative to allowing anyone to execute a Smart Agreement is to allow only a specific, pre-determined "someone" to serve as the executor. The public key of the Authorized Executor must be entered as part of the definition of the Smart Agreement. If another agent attempts to Execute the agreement, their attempt would be recognized as invalid by any other peer.

Unyt does not currently support having two or more specific Authorized Executors.

#### ROLES

Roles enable you to grant authorizations based on membership in a class.

Roles are Defined in the Agreement Definition section of the Code Template.

Editing a Role involves creating a Description and Selecting whether the Role is available to anyone or only to Authorized Agents.

There are three options for Qualification Type:

1) Anyone
Anyone can interact with the Smart Agreement through this Role

2) Authorized
Only specific Authorized Agents can interact with the Smart Agreement through this Role

Later, we intend to add support for Delegated Authorization (an example context might involve Know-Your-Customer or KYC type assertions), where a specific third party can authorize an agent to interact with the Smart Agreement through this Role. This feature is planned, but has not yet been built.

A Smart Agreement can include multiple roles.

#### INPUT RULES

For each input property defined in the Agreement Code Template, you will need to select a Source where the Executor will obtain that input when they are assembling content to Execute the Smart Agreement and produce a SAVED.

There are 4 different types of Sources that you can require an Input to come from:

1) Provided By

You can require that a particular input be provided by an agent interacting with the Smart Agreement through a particular Role.

2) Executor Provided

The input is provided by the Executor themselves.

3) Fixed

The input is defined (hard coded) into the agreement itself at the time the agreement is created.

4) Query

You can define a query that the executor will perform when gathering inputs for execution and will include the results of the query as the input.

Once a Smart Agreement has been published, it will appear in the Agreement Code section under the folder that it was published to (ex: Public, Private).

#### Examples and Guidance for Creating Custom Smart Agreements

We want to help you create custom Agreement Code Templates and Smart Agreements that you believe might be useful in your context. To that end, we have created a Templates and Agreements Library as a Github Repository. It has some additional examples and guidance and we would love to have you create new Templates and Agreements, try them out in Unyt and add them to the [Smart Agreement Library](https://github.com/unytco/smart_agreement_library). This is a Repo that will enable sharing across Unyt Accounting Alliances enabling a wider community of projects to view, play with, and gain inspiration from one anothers' Smart Agreement efforts.

For a summary and guidance, start by looking at the comments at the top of the execution_code.rhai file in any particular Template. Any example Smart Agreements should be stored in an Agreements directory within each particular Agreement Code Template directory.

### Viewing Code Templates and Smart Agreements

If you open one of the Folders in the Build Panel, it will show you any Code Templates and Smart Agreements that have been published to that Folder.

Click on any Code Template or Smart Agreement to open it. You can then view the details.

On the upper right, you will find buttons to Edit, Copy or Archive the Code Template or Smart Agreement. 

Edit enables any authorized editor to edit the content.

Copy will create a new version, with the current version serving as a starting point that can be edited to produce a new, different Code Template or Smart Agreement.

### Coming Soon: DATA RECORDS

The backend code for Data Records is already present, but the front end user interface is still in development.

Data Records enable agents to store larger files and pieces of content in a way that can be referenced from elsewhere within the software, for instance as an input to a Smart Agreement.

There are a few different types of Data Records that can be created at present:
a Conversion Table, a Recipe, and a Code Sheet. Each of these could be used to define service pricing. The Code Sheet could also be used for other more general purposes.

#### Creating New Data Records

##### Create a Conversion Table

Creating a Conversion Table involves defining the number of Service Units required to equate to 1 Fuel Credit. This can then be referred to from within a Smart Agreement, resulting in a fixed price in Fuel Credits for a specific service. 

##### Create a Recipe

On the other hand, a Recipe enables one or more Service Units to be defined in relationship to 1 Fuel Credit. In some ways, this results in a basket of goods pricing structure. For instance, 1 HF might buy you 3 gigabytes of Bandwidth and 4 Requests.

##### Create a Code Sheet

A code sheet allows you to define custom logic for a price sheet.

##### Create a New Data Record

You can create any sort of Data Record that you want, in JSON format. 

#### DATA RECORDS TABLE

In the DATA RECORDS TABLE, each row will display the following details for a specific Data Record:
ID, PREVIEW, DATA, and TIMESTAMP.

##### Data Record ID 

Data Record ID displays the Identifier for the Data Record. Hovering over it will display the DR ID. Clicking it will copy the DR ID to the clipboard.

##### Preview

PREVIEW shows a short snippet of text from the Data Record.

##### Data

Clicking on the document will bring up a modal with the full text of the Data Record.

##### Date

Date shows the creation date and time of the Data Record.

## SERVICE NETWORKS

The Service Networks Tab is focused on enabling the Configuration of portions of the Unyt Accounting Alliance Application that will be stewarded by particular Service Networks in that Alliance.

#### GLOBAL 

Global Settings are visible in the Build Tab, but are editable only by the progenitor admin.

In Unyt Apps, a progenitor agent plays the role of setting up and updating the basic ground rules for that particular Unyt Alliance.

#### GLOBAL CONFIGURATION

At any one point in time, there is a single ruleset that governs this Unyt Alliance as a whole. We refer to to the ruleset as the Global Config (Configuration). We refer to the particular period of time that a particular Global Config ruleset is in effect as the Global Config Window.

A Global Configuration can have a handful of components:

- Global Config Window
  - Effective Start Date
  - Expiration Date
- System Agreements
  - Compute Credit Limit Agreement
  - Compute Transaction Fee Agreement
  - Fee Trigger
  - Fee Percentage
- Additional Information
  - Additional Special Agents
  - Global Configuration declared Smart Agreements

Lets walk through each of them 

##### Global Configuration Window

A Global Config Window has an Effective Start Date as well as an Expiration Date.

Between the Effective Start Date and the Expiration Date, any action that is attempted by any participant must not violate any of the rules established in the Global Configuration. After the Expiration Date, interactions must comply with whatever Global Configuration Ruleset is in effect for that period of time.

##### SYSTEM AGREEMENTS

###### Compute Credit Limit Agreement

This agreement determines how the Credit Limit check will be performed, including which Smart Agreement will need to be run when performing a check of a credit limit.

###### Compute Transaction Fee Agreement

This determines how Transaction Fees are calculated. Since Transaction Fees can accumulate before being submitted, the Compute Transaction Fee Agreement determines the threshold at which transactions fees must be paid before an agent can continue to transact. This is typically handled in an automated manner.

###### Fee Trigger

Displays the Fee Trigger Threshold. No transaction that makes fees accumulate beyond this threshold should process successfully until the outstanding fees have been paid.

###### Fee Percentage

Displays the Transaction Fee Percentage that is charged on all Spend Transactions.

##### ADDITIONAL INFORMATION

We have created a couple of additional experimental features to make it easier for Service Networks to create neutral territory for Smart Agreements and manage their interactions with other Service Networks within that Unyt Alliance.

###### ADDITIONAL SPECIAL AGENTS

Special Agents are agents given some particular permissions or rights, similar to Roles in a Smart Agreement, but declared at the level of the Unyt Alliance for the duration of that Global Config Window.

###### ADDITIONAL SPECIAL SMART AGREEMENTS 

Service Networks can set up Smart Agreements that are defined at the Alliance level.

#### SERVICE UNITS

This is where we can create the different Units that this particular Unyt Alliance will use. Each type of Unit will have a Symbol, and Title, and a Description. Each Unit is able to represented by a floating point number (i.e something like 3.14).

##### BASE UNITS

The first Service Unit that is declared serves as the BASE UNIT for this Unyt Alliance. It can be edited by the Global Admin. This will serve as the main payment unit.

##### NON-FUEL SERVICE UNITS

Subsequent Service Units are quantifiable (i.e. countable) units related to different forms of service provision. These should be defined in ways that fit with the kinds of services being provided (and tracked) within the Service Networks participating in this Unyt Alliance. A cloud computing Service Network might track Bandwidth, Processing, and Requests. A storage network would certainly track Storage. A wifi hotspot Service Network might track connections and authorization for access to wifi service, perhaps on a time basis (5 minute intervals) with additional tracking of Bandwidth provided.

In general, when a customer pays for Services from a Service Network, they will pay with BASE UNITS, and will receive Services. When they do, the accounting alliance generally accounts for the specific services that have been provided on their behalf by showing that they have received those Service Units.

#### Service Networks

Service Networks are the different participating member projects that form the backbone of a particular Unyt Accounting Alliance. At present, many of these will be Decentralized Physical Infrastructure projects like Holo Hosting that are creating a two-sided marketplace with Service Providers and purchasers of those services and ways to track that provision of services. 

##### INITIALIZE SERVICE NETWORK

The Global Config Admin is able to set up a new Service Network. Initializing a Service Network involves creating the initial Service Network Configuration.  



##### SERVICE NETWORK CONFIG

Similar to the Global Config, a Service Network Config is the ruleset that governs the operation of a particular Service Network within a Unyt Alliance. This includes the definitions, properties, smart agreements and authorizations that govern that Service Network's operations within Unyt. The Service Network Config includes the following:

##### BASIC PROPERTIES

###### NAME

The Name of the Service Network

###### Shortcode

The Abbreviation of the Service Network Name

###### THEME COLOR
Color to make this Service Network visibly distinct from others.

###### DESCRIPTION
Add a description of the Service Network.

###### PROJECT WEB ADDRESS (optional)

Add a web address for the Service Network

###### EXTERNAL REDEMPTION UNIT

Name of the Service Network's Outside Currency (if any).

###### EXTERNAL REDEMPTION UNIT SHORT CODE

Symbol of the Service Network's Outside Currency (if any).





###### EFFECTIVE START DATE

Date and Time where this Service Network Configuration Window becomes effective. During the period it is in effect, any interactions with Service Network Agreements must adhere to this configuration.

###### EXPIRATION DATE

Date and Time that this particular Service Network Configuration Window ceases to be in force.

##### SPECIAL AGENTS

A Service Network can define a number of special agents. These can be added to people's address book so that they can confirm that they are interacting with the officially identified parties playing those particular roles.

###### BRIDGE AGENT

Service Networks that have an Outside Currency and want to offer a way for holders of that Outside Currency to purchase Base Units, need to assign an agent that is authorized to perform such sales on behalf of the Service Network. The Bridge Agent is responsible for obtaining the proof of deposit in the Outside Currency, whether that proof is through a Blockchain Transaction, a Bank Transaction or in some other manner, and serve as Executor of the Transaction where that External Proof is being provided and Base Units are being transferred to the Purchaser.

By default, this same Bridging Agent plays the same role when the reverse course of action is being followed. A Service Provider who has earned Base Units through work in that Service Network can Redeem those Base Units for that Service Network's Outside Currency. During this Redemption process, the Bridge Agent similarly Executes the transaction where the Base Units are being received by the Service Network and authorizes the payment out to the Redeemer through the appropriate method in the relevant Outside Currency.

###### SERVICE INFRASTRUCTURE ACCOUNT

Each Unyt Accounting Alliance sets its own policies regarding how participating Service Networks are able to establish credit within the Alliance. Access to an interest-free credit line can be a significant benefit for participating Service Networks.

This access to credit may enable participating Service Networks to capitalize infrastructure or other investments using the internal credit system of the Unyt Alliance rather than having to resort to outside sources such as obtaining a bank loan (where they would have to pay principle plus interest) or selling a portion of the Service Network's equity or token treasury (which would dilute existing shareholders, and depending on circumstances can ultimately result in a loss of control of their company).

In order for a Service Network to receive a line of credit, they need to assign an Agent (a public key) as the steward of their credit line. We call this their Service Infrastructure Account. As the Service Network establishes a credit limit in accordance with that Unyt Alliance's policies, the Service Infrastructure Account is the agent to whom that credit limit gets allocated. This agent can then spend up to that credit limit.

###### OPS ACCOUNTS

An operations account that can take actions on behalf of that Service Network. For instance, might pay employees a portion of their salary in Base Units.

###### EDITORS 

Agents authorized to serve as Service Network Admins can make changes to this Service Network Configuration and should be authors of any Service Network Smart Agreements.

##### SMART AGREEMENTS

Service Networks will generally make use of 3 different primary forms of Smart Agreements:
a Purchase Agreement, a Redemption Agreement and a Proof of Service Agreement.

To add any of these Smart Agreements, first create the specific Smart Agreement in the Build Panel and then copy the Agreement ID and paste it into the field for the relevant agreement.  There are some examples already published in the Build Panel that you can Copy and modify to meet your Service Network's needs.

###### LANE PURCHASE OF UNITS

This is the agreement governing the Purchase of Base Units by Purchasers from the Service Network. They pay with a pre-defined Outside Currency according to the pricing algorithm defined by the Unyt Alliance. The purchase must be Executed by the Service Network's Bridging Agent.

###### LANE REDEMPTION OF UNITS

This is the agreement governing the Redemption of Base Units by Service Providers to the Service Network. Sales and Redemptions are really a means of enabling parties to "Purchase From" and "Redeem To" that particular Service Network's Fuel Credit Treasury within the Unyt Alliance. Redeemers receive from the Service Network the pre-defined Outside Currency according to the pricing at which previous Sales of Fuel Credits had occurred. The Redemption must be Executed by the Service Network's Briding Agent.

After each Sale or Redemption transaction (which the Bridging Agent is always participating in), the Current Redemption Rate gets recalculated - based on a simple Redemption Rate algorithm that takes in the number and price of all Fuel Credits sold and subtracts the number and price of all Fuel Credits already redeemed. Thus the Current Redemption Rate is simply the Average Sales Price of Fuel Credits that have been sold by the Service Network, but not yet Redeemed.

###### PROOF OF SERVICE

This is the agreement governing the methods by which Service Providers (or something like a Service Network Invoice Gateway) proves that particular agents have actually Provided Services as part of that Service Network. It also supports agents that want to Pay for Services to do so through a Spender Interaction with this agreement.

In addition to being useful as a part of the integrity process that ensures that those paying for the services are paying for actual value creation, Proofs of Service are helpful in establishing the credibility, and consequent credit limits of particular Service Providers.

Finally, each Service Network will themselves support Redemptions to an Outside Currency only to Service Providers, and only up to a quantity of Base Units equivalent to what has been earned through Service Provision as established through Proofs of Service.  

This principle of Redemption support only for Service Providers helps ensure that any arbitrage type activity within the Unyt Alliance itself is mediated by actual Service Provision, and thus is tied to real Value Creation, as defined by the Alliance's governing rules. This helps ensure that the Base Units are backed by the demonstrated capacity to perform valued work on behalf of others who are willing to pay for it.

##### SERVICE NETWORK CONSOLE

Once a Service Network has been initialized by the Global Progenitor, the Authorized Service Network Admin(s) are able to update that Service Network Configuration using the Service Network Console. This can be accessed by clicking on the Update Properties button with the Service Networks section of the Admin tab.

The Service Networks tab gives a single place to find all of the relevant Smart Agreements, Data Records, and Calculated Redemption Rates for each Service Network, or set up new ones.

Each Service Network that is participating as a member in the Unyt Alliance has their own area within the Service Networks tab.

For any particular Service Network, the following pieces of content would typically be made available for interaction:

- Smart Agreement for Purchase of Base Units
- Smart Agreement for Redemption of Base Units
- Smart Agreement for Proof of Service

Each of those Smart Agreements is also available in the Build Panel, but this page assembles them alongside the below bits of information for a better user experience.

Means for Bridge Agent to Add a conversion sheet that governs the pricing of the Sale of Fuel Credits for Outside Currency.

Means to Drop off Proofs of Deposit for Payments of Outside Currency used by others to purchase Fuel Credits.

Means for Bridge Agent to Redeem Fuel Credits for Outside Currency.

In addition there is an informative "Most Recent Redemption Rate" which is calculated based on the Average Sales Price (in Outside Currency) of all unredeemed Base Units that had previously been sold by the Service Network for Outside Currency.

And that is a wrap of the walk through of Unyt.

If you have any thoughts, questions or criticisms, please feel free to add items to our [feedback board](https://github.com/orgs/unytco/projects/5/views/1), and don't hesitate to reach out to our team.
