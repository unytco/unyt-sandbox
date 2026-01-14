#

- check if creating 2 release will spin up

- put the menu back in and test

## Tech Debt

- see that if an migration is triggered but the DNA's are the same it makes a decision, so that the app does not fail to start up

## Future Features?

- splash screen
- tray for most OS

## For debuging a live app or a .deb installed app

update the tauri.config.json to build only `deb` insted of all
and run:
`yarn tauri build`

Install the app:

To view logs

```
 journalctl --user -f | grep -i unyt
```
