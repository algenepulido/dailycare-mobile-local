# Cleartext, and why the exception does not ship

A release build refuses plain HTTP. That is Android's default since API 28 and it is the
right one: the API is HTTPS on Cloud Run, and a build that would talk to `http://`
anywhere is a build that can be pointed at a proxy on a ward's wifi.

It is also what stops a local emulator from reaching a local API, which is where this gets
tested before anything is deployed. `10.0.2.2` is the emulator's alias for the machine
running it, and that is the address a debug build needs to reach.

## What changed, and why

This used to be one file with one exception in it, and that file shipped. The reasoning
written beside it was that `10.0.2.2` is not a real address — that it exists only inside
the emulator, so a build carrying the exception could not be talked into a cleartext
conversation with anything that exists.

That is not true. `10.0.2.2` is an ordinary RFC 1918 address. A care home running
`10.0.0.0/8` can have a real host at exactly that number, and a release build carrying the
exception would speak plain HTTP to it. The argument was comfortable and wrong, which is
the worst combination for a security control: it reads like a reason.

So there are two files now:

    network_security_config.xml         cleartext off, no exceptions   — ships
    network_security_config.debug.xml   the 10.0.2.2 exception         — debug only

`plugin.js` writes the first to `app/src/main/res/xml/` and the second to
`app/src/debug/res/xml/`. The Android resource merger prefers the build type's copy, so a
debug build has the exception and a release build has no way to get it. There is no flag
and nothing to remember, which matters more than the argument above — the previous
arrangement depended on a person reading a comment and agreeing with it.

## Checking it

The compiled config is a binary XML resource inside the APK, so grep the built artifact
rather than the source:

    unzip -o -q app-release.apk -d /tmp/apk
    grep -rl 10.0.2.2 /tmp/apk/res

Nothing should come back for a release build. A debug build should name one file.
