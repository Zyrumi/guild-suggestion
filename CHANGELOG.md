# GuildSuggestion 0.3.1

- Fixed: Invite no longer tries to send the guild invite itself. WoW only lets its own interface send guild invites, so the addon's attempt was blocked. Invite now shows the exact command to type in chat (`/ginvite First Surname`), and the suggestion is marked invited once the game confirms it, however you sent the invite.
- New: Log tab for members who can invite, with every suggestion, invite, decline and removal, and when it happened.
- Removing a decided suggestion no longer erases who decided it.
