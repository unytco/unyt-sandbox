# Unyt Dictionary

#### links to related docs

- [Invitation to Play](./1_0_invite.md)
- [Unyt Setup](../README.md)
- [Detailed Documentation](./5_0_phase_5_testing_details.md)
- [Unyt Dictionary](./4_2_unyt-dictionary.md)
- [Intro to Smart Agreements (Three Layers)](./4_1_intro_to_smart_agreements.md)
- [Templates and Smart Agreements Library Repo](https://github.com/unytco/smart_agreement_library)
- [Feedback](https://github.com/orgs/unytco/projects/5/views/1)


## A glossary of terms related to Unyt

**Action List**
: Displays in-process transactions that are Actionable (requiring your action).

**Accept**
: The action taken by a Receiver to formally acknowledge and receive Base Units and/or Service Units into their account balance.

**Agent**
: A participant in a Unyt Alliance.

**Agent Key**
: A participant's identifier in a Unyt Alliance, represented by the public portion of a public/private key pair, used for all interactions and transactions.

**Agent Overview**
: A sidebar section in the Unyt interface showing an Agent's own address, Name, Address Contacts, Credit Limit, Unit Balances.

**Agreement Code Template (Template)**
: Defines core reusable logic for Smart Agreements, including input/output schemas and execution code.

**Code Sheet (Data Record)**
: A flexible Data Record for custom logic, price sheets, or other publishable data referenced by participants.

**Compute Transaction Fee Agreement**
: A System Agreement within the Global Configuration that determines how Transaction Fees are calculated and their payment threshold.

**Conversion Table (Data Record)**
: A Data Record defining a fixed price by equating a number of Service Units to 1 Fuel Credit.

**Credit Limit**
: The amount below zero an Agent can spend in a particular unit, especially in the Base Unit, as determined by the System Credit Limit Computation agreement in their Unyt Accounting Alliance App. 

**Data Records**
: Stored content (e.g., Conversion Table, Recipe, Code Sheet) referenced by Smart Agreements, often for service pricing.

**DePIN (Decentralized Physical Infrastructure Networks)**
: Networks Unyt primarily supports, focusing on high-volume, low-cost transactions for real-world services.

**Executor**
: An Agent authorized to perform the execution of a Smart Agreement, transforming its inputs into outputs according to its defined rules.

**Transaction Fee Percentage**
: The percentage rate charged as a Transaction Fee on Spend transactions, defined in the Global Configuration.

**Transaction Fee Trigger**
: The threshold defined in the Global Configuration prior to which accumulated Transaction Fees must be paid.

**Fees Owed**
: Transaction Fees that have accrued from an Agent's activities but have not yet been paid.

**Base Unit**
: The generic term for the primary, internal payment unit of account within a Unyt Alliance. Each Unyt Alliance will choose a name and symbol for their community's own Base Unit.

**Global Config**
: The overall ruleset, including System Agreements, governing a Unyt Alliance for a specific Global Configuration Window.

**Global Config Window**
: The specific period during which a particular Global Configuration is active and its rules are in effect.

**Identicon**
: A unique, colorful visual image generated from an Agent's public key to help in recognizing and differentiating Agents.

**Request**
: A request for Base Units and/or Service Units sent from one Agent to another Agent.

**Library (Templates and Agreements Library)**
: A central repository within Unyt where participants in that Unyt Alliance can create, find, and interact with Agreement Code Templates and Smart Agreements.

**Parked (Transaction Type)**
: A transaction status indicating a submission of content (e.g. an invoice, attestation) to a Smart Agreement.

**ParkedSpend (Transaction Type)**
: A transaction representing the sending of Base Units by a Spender directly to a Smart Agreement.

**Proof of Service Agreement (Service Network)**
: A Smart Agreement used within a Service Network for Service Providers to prove that services have been rendered and for Payors to Park Spends as payment for such services.

**Purchase Agreement (Service Network)**
: A Smart Agreement governing the purchase of Base Units from a particular Service Network within that Unyt Alliance, with payment in that Service Network's Outside Currency.

**Recipe (Data Record)**
: A Data Record defining a "basket of goods" where 1 Base Unit equates to a bundle of one or more Service Units in specified quantities.

**Receiver**
: An Agent designated to receive Base Units or Service Units in a transaction or as an output of the execution of a Smart Agreement.

**Redemption Agent (in Service Network)**
: An Agent authorized within a Service Network to manage the redemption of Base Units for an Outside Currency.

**Redemption Agreement (Service Network)**
: A Smart Agreement governing the redemption of Base Units by a Service Network's Service Providers, redeeming into that Service Network's Outside Currency. 

**Redemption Fee**
: Not explicitly defined as a standard system-wide fee. Any such fees are to be defined by a Service Network's custom Redemption Agreement logic or pricing structure.

**Role (in Smart Agreement)**
: Defines a class of Agents (e.g., "Vendor," "Customer") and grants specific authorizations for interacting with a Smart Agreement.

**Sales Agent (in Service Network)**
: An Agent authorized within a Service Network to manage sales of Base Units for an Outside Currency (through a Purchase Agreement).

**SAVED (Smart Agreement Verifiable Execution Doc)**
: The immutable documentation resulting from the valid execution of a Smart Agreement by an Executor, published for verification. Any application participant can validate that the Smart Agreement was executed appropriately.

**Send**
: The action taken by a Sender to send Units, whether Base Units and/or Service Units, sometimes of thier own initiative, sometimes in response to an Invoice, and other times as a way of interacting with a Smart Agreement.

**Sender**
: An Agent that authorizes a transaction that involves debiting Units from their account, such as a direct Spend or payment via a Smart Agreement.

**Service Fee**
: A charge that can be levied (by a Service Network) for services rendered or transactions processed. Not defined a standard system-wide fee. Can be defined within Smart Agreements.

**Service Network**
: An organization within a Unyt Alliance, set up by that Alliances Global Admin, that defines its own configuration, services, and typically uses specific Smart Agreements for its operations. 

**Service Network Console** 
: The admin interface where a Service Network Administrator defines and stewards a Service Network's Configuration including the definition of Service Units and of Smart Agreements.

**Service Network Admin** 
: An Agent authorized by the Global Admin to manage and make changes to a specific Service Network's Configuration.

**Service Network Config**
: The specific ruleset for a Service Network, effective for a defined period, governing interactions with its associated Smart Agreements.

**Service Units**
: Quantifiable units, distinct from Base Units, used for tracking specific forms of service provision within a Unyt Alliance. An agent's balance in a particular Service Unit may move in the opposite direction (up / down) of the Base Units involved in that same transaction, if it changes at all.

**Smart Agreements**
: Customizable, agent-centric programs in Unyt that define rules and logic for interactions and transactions, an alternative to blockchain smart contracts.

**System Agreements**
: Core agreements defined within the Global Configuration of a Domino Alliance, such as the Compute Credit Limit Agreement and Compute Transaction Fee Agreement.

**Transaction Fee**
: A fee, typically a percentage, charged by a Unyt Alliance when Base Units are spent, as defined in its Global Configuration.

**Unclaimed (Credits)**
: Base Units that have been allocated or sent to an Agent but have not yet been formally accepted by them into their balance.

**Unyt**
: Decentralized software for microtransaction accounting, enabling communities to run their own peer-to-peer Unyt Accounting Alliances.

**Unyt Accounting Alliance (Unyt Alliance)**
: A community that is together running a particular Unyt Alliance App.

**Unyt Alliance App**
: A customized white-labeled custom version of Unyt that a Unyt Accounting Alliance runs as a decentralized accounting, credit and payments system, with its own rules, Base Unit, Service Units and Smart Agreements.

**Watched List**
: Interactions that you have marked as Watched Items. Can include items that have been completed as well as items awaiting an action by another party.