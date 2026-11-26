# GuildSuggestion 0.4.0

- Fixed: Invite no longer tries to send the guild invite itself (WoW only lets its own window do that, so it was blocked). Invite now shows the player's name ready to copy at the bottom of the To decide page and highlights Blizzard's Invite Member button: copy it, click Invite Member, paste, Accept. No typing of names with special characters.
- The suggestion is marked invited once the game confirms the invite went out, however you sent it.
- New Log tab for members who can invite, with every suggestion, invite, decline and removal, and when it happened. Removing a decided suggestion no longer erases who decided it.
- Suggest, To decide and Log are game-style tabs.
- Lists use the game's own scroll bar, and only scroll when there are more entries than fit.
- Your suggestions take one line each (hover for the reason), with a small X to remove one and a Clear list button.
- Suggested players show their level and class (picked up when the suggester has them targeted or in their group, and whenever anyone with the addon targets or mouses over them), so you know who you're inviting. Names are in class colours.
- Log filters: who did it and what action.
