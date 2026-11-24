# Security policy

Please report vulnerabilities privately, not in a public issue. Use GitHub's
**Report a vulnerability** button on this repository's **Security** tab
(private vulnerability reporting).

Include the app, platform and version, what an attacker can do, and steps to
reproduce. You will get a reply within a week. Please give us a reasonable time
to ship a fix through the app stores before you disclose details.

Only the latest store release of each app is supported with security fixes.

Things worth reporting: sign-in tokens or passwords stored or logged insecurely,
an app sending credentials over plain HTTP when the user chose HTTPS, requests
to hosts the user didn't configure, one profile reading another profile's data
on a shared device, and ways for a malicious server response to run code or
read files on the device.

Problems in the Jellyfin server itself belong with the Jellyfin project, and
problems in the Zorofin plugin or companion belong in their own repositories.
