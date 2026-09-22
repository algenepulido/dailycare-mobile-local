# Why the app can talk to the network now

Milestone one blocked `android.permission.INTERNET` outright. That was not an oversight to
tidy up later — it was the strongest claim the app could make. A build without that
permission cannot send a resident's name anywhere no matter what the code does, and
"cannot" is a different kind of statement from "does not".

Milestone two is accounts and data moving between devices, so the permission has to come
back. What replaces it is not as strong, and it is worth writing down what the trade
actually is rather than deleting a line from `app.json` and moving on.

What the app gave up: a guarantee enforced by the operating system, checkable by anybody
with `aapt2` and thirty seconds.

What stands in its place:

- One base URL, read from `EXPO_PUBLIC_API_URL` at build time, so where a build talks is a
  property of the build rather than of something it fetched.
- Every request goes through `src/data/api.ts`. There is no other `fetch` in the app, and
  that is checkable: `grep -rn "fetch(" src/` should find one file.
- The server decides what a request may see. A phone holding a valid token for a caregiver
  at Cedar still gets nothing about Birch, because the policies answer that question and
  the API has no way to override them.
- Photographs still go to the device first and are removed with the session. The network
  path for them does not exist yet.

The permission list in a release build is still worth reading, and `RECORD_AUDIO` and
`SYSTEM_ALERT_WINDOW` are still blocked. Neither has a reason to be there and both are
what somebody would add without thinking if a library asked.
