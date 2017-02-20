# Verify-Roster

A *really* simple vibe.d app that checks whether the players on a tf2 server
match the players signed up to play on
[citadel](https://github.com/ozfortress/citadel).

## Dependencies

[D](https://dlang.org) and [vibe.d](http://vibed.org/)

## Building

```bash
dub build
```

## Deploying

We deploy using [capistrano](http://capistranorb.com/).

```bash
cap production deploy
```
