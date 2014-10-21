## Snowdock

Snowdock is a docker deployment utility, with special support for hot-swapping updates to websites.

Under the hood it uses [hipache](...) to proxy requests to several backend docker containers. Hipache allows us to deploy a new version of the website while keeping the old one active, then switching it off when the new website is up and running.
