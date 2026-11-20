# Microsoft Teams (chat)

What is particular to Teams when the chat skill writes a message.

- The link opens a 1:1 chat with the message already in the compose box (`prefilled` is always true). The person reads it and presses Send.
- Plain text only: Teams shows `**` and backticks literally. Use `-` and `1.` for lists.
- If Teams does not open (no desktop app, a blocked protocol), run the script with `-Copy` instead of `-Open` and tell the person to paste the link in the browser.
- Never paste the URL into the chat as a link: it repeats the whole message, encoded, and runs to hundreds of characters, and a terminal breaks it over several lines.
- A warning that the link is long (`providers.teams.maxLinkLength`) means Teams may cut the message; shorten it.
