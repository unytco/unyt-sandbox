#### links to related docs

- [Invitation to Play](./1_0_invite.md)
- [Unyt Setup](./README.md)
- [Detailed Documentation](./5_0_phase_5_testing_details.md)
- [Unyt Dictionary](./4_2_unyt-dictionary.md)
- [Intro to Smart Agreements (Three Layers)](./4_1_intro_to_smart_agreements.md)
- [Templates and Smart Agreements Library Repo](https://github.com/unytco/smart_agreement_library)
- [Feedback](https://github.com/orgs/unytco/projects/5/views/1)

### Smart Agreements enable Flexibility
Holochain enables applications to run peer-to-peer, in part by agreeing on the rules of the application up front. When someone makes an adjustment to the rules in a new version, however, they may find that they have put themselves into a new app network, no longer in communication with the people that are still running the old version. The "hard coding" of rules is powerful, but can be rigid.

Smart Agreements enable people inside of a Holochain application to craft their own "additional rules for interaction" without having to create a new version of the app. So Smart Agreements enable a "soft coding" of rules, and those who chose to interact with those particular agreements do so in accordance with those rules.

Different communities can set up their own version of Unyt with their own preferred Smart Agreements. And a particular community can iterate on its agreements over time without having to create a new version of the app. So Smart Agreements add a bit of flexibility.

### Agent Centric
Smart Agreements make use of the agent-centric nature of holochain. Someone publishes a Smart Agreement into the community space. One or more people might interact with the agreement, whether that involves publishing an invoice, paying some credits or some other action.

In order of the agreement to actually run, someone will have to execute it. Depending on the agreement, it might be that anyone can execute the agreemnt. It might be that just one specific agent is authorized to execute. 

Execution involves collecting inputs, transforming them in accordance with the code in the agreement, and producing outputs. Anyone who runs the agreement with that same set of inputs will get the same outputs. So even though a particular agent may be the one authorized to execute, they aren't able to modify the agreement or dictate the outputs independent of the agreement itself. All they can do is run those inputs with the Smart Agreement code.

That will produce a Record of that execution, which the Executor will publish. We call it a Record of Agreement Verifiably Executed (RAVE). Others will validate that the RAVE is the result of an appropriate execution of the Smart Agreement.

If the RAVE allocates units to one or more agents, the Executor will automatically notify them that they have units to accept.

And while much of this storytelling has focused on Smart Agreements that have to do with payments, that is just one way that they can be used. There is a lot of flexibility in terms of what can be done with Smart Agreements.

But lets also open up some of the interesting things that arise out of making agents central to the operation of a decentralized network.

#### Lightweight Transactions and Interactions

Unyt, like Holochain apps more generally, does not rely upon a centralized server for validating, storing and serving transactions. It also does not need a group of validators coming to consensus about the total order of all events. Instead, each agent is the authority about the order of the actions that they have taken and each action is subsequently validated, stored and served by a portion of the participating peers.

This approach makes it possible to handle high volumes of participants, and high volumes of transactions, while keeping the computational costs low and enabling full participation using ordinary consumer devices. 

Layering on top of this foundation, different communities can structure things in a variety of ways to support different priorities. For instance, some may want to enable a portion of their community to use lightweight nodes that don't have any responsibility for validating, storing and serving content from peers. 

#### Asynchronous Transactions
Whether Alice is sending directly to Bob, or is paying for a service using a Smart Agreement, as soon as she hits send, her account get's debited. If she was offline when she prepared the transaction, it will go through when she comes online. If she then goes offline again, it doesn't matter. That content has been shared with others and the rest of the network will recognize that Alice has chosen to take that action. Assuming she sent them to a Smart Agreement, when the Executor of that agreement next executes it (some agreements can be executed repeatedly), they will include Alice's payment as one of the inputs. And if one of the results of that execution is that some units got allocated to Bob, those will get allocated right away. If Bob is offline, he'll get notified when he comes back online, and at that time can choose whether or not to accept the units. If accepts them, his balance will change. If he doesn't, they will remain available for him to accept. Nobody else can claim them. 

#### Bulk transactions
Agent-centric Smart Agreements also support many people interacting with an agreement, perhaps thousands adding invoices, and just as many interacting with it by making payments. After an execution of that agreement there might be thousands of people notified that they can accept units that have been allocated to them. Again, as each of them accept the payments, their account will be credited.

### Time is Weird

This true in general. Einstein figured out over 100 years ago that there is no absolute order of events with his Theory of Relativity. But the strangeness of this reality confronts us bluntly when we create peer-to-peer applications, especially devices turning off and on, or with inconsistent internet connectivity and then start asking questions like "when did this action happen?" 

When according to who? Without deciding that some particular party or group is the "official" keeper of time or of the ordering of events, we can get conflicting answers. Oftentimes, that is not problematic. Sometimes it is. There are advantages to the agent-centric approach that Unyt and Holochain are making use of (like enabling actions to be taken while offline), but it is true that none of this is simple. In some ways the agent centric approach leads us to confront the strangeness of time rather than simply ignore it. But it also unlocks new, more sophisticated patterns of coordination that have proven out of reach with the "simpler" approaches.

### Updating Smart Agreements
The current way in which Unyt enables the updating of Smart Agreements, at least those that are intended to act as the super-structure of the application involve aligning on the window of time that a particular set of agreements will govern activity in the app.

A particular set of System Wide Smart Agreements are enforced during a particular Global Config Window, which has an Effective Start Date and an Expiration Date. During a particular Global Config Window, all actions must not violate any of the rules established by the System Wide Smart Agreements in the Global Configuration. After the Expiration Date, a new Global Config Window with its own set of Smart Agreements (possibly the same as the prior window) will be in force. 

There is also a Service Network Config Window that operates similarly, but for a portion of the application (essentially a sub-community) with its own particular set of Smart Agreements that can be iterated on using the same pattern of Effective Start Dates and Expiration Dates. 

Other (nonsystem level) agreements can be updated at any time.

This approach isn't as flexible as being able to change all agreements at any time, but given some of the earlier points that we've mentioned about time in distributed systems, it is an approach that enables iteration, while delivering consistent aligment on which rules are in force and enables the enforcement of those rules. The duration of a config window could be set to last for a very short period of time (an hour, or a day) or for something longer (a month, perhaps).

If you want to dive into how Smart Agreements are structured, check out our [Intro to Smart Agreements (Three Layers)](./4_1_intro_to_smart_agreements.md). And if you want to see some guidance and examples and possibly even create your own, see our [Templates and Smart Agreements Library](https://github.com/unytco/smart_agreement_library).