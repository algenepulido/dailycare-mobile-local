# Cleartext, and why only to one address

A release build refuses plain HTTP. That is Android's default since API 28 and it is the
right one: the API is HTTPS on Cloud Run, and a build that would talk to `http://` anywhere
is a build that can be pointed at a proxy on a ward's wifi.

It is also what stops a local emulator from reaching a local API, which is where this is
tested before anything is deployed. The choice is between turning cleartext on for the
whole app and turning it on for the one address the emulator uses to reach the host.

`10.0.2.2` is that address, and it is not routable from anywhere else — it exists only
inside the Android emulator, as an alias for the machine running it. A build carrying this
exception cannot be made to talk plainly to a real host by DNS, by a captive portal, or by
anything else, because there is no real host with that address.
