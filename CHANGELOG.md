# GuildSuggestion 0.3.0

First public release.

Any guild member can suggest a player to invite, with a short reason. Members whose rank can invite see each suggestion on a To decide list in the guild window and choose Invite or Decline. The member who made the suggestion sees what happened.

- Guild suggestions tab in the Guild & Communities window, with Suggest, To decide and Log tabs
- Invite works like typing `/ginvite` (the game only lets its own UI send guild invites); during a fight it waits until the fight is over
- Log tab for members who can invite: who suggested whom, who invited or declined, who removed it from the list, with date and time
- Right-click a player and pick "Suggest for guild invite", or type `/gsuggest`, `/gsuggest First Surname` or `/gsuggest %t`
- Reasons are only sent to members whose rank can invite
- Suggestions wait until someone who can invite is online at the same time, and inviters keep their lists in step
