# Mythic Beasts DNS manager

A simple management agent for controlling your DNS entries on the Mythic Beasts platform using a (version-controllable) YAML file.

This client uses the DNSv2 API (https://www.mythic-beasts.com/support/api/dnsv2) for which you'll need to create a key (https://www.mythic-beasts.com/customer/api-users).

## Configuration

1. Create an API key via https://www.mythic-beasts.com/customer/api-users
2. Create a YAML file

```yaml
defaults:
  ttl:
    example.com: 3600
  api: https://api.mythic-beasts.com/dns/v2/zones
  api_host: api.mythic-beasts.com:443
  realm: Mythic Beasts DNS API

auth:
  key: mykey
  secret: mysecret

zones:
  example.com:
```

3. Under `zones -> example.com`, prepare your DNS entries using the schema:

```yaml
zones:
  example.com:
    name1:
      TYPE: value
    name2:
      TYPE:
        - value1
        - value2
    name3.subdomain:
      TYPE: value
```

Currently only a single zone is supported.

## Supported types

The client currently supports all of the Record Types implemented by the Mythic Beasts API.

## Value syntax

The value for simple record types is the plain value as expected (eg. `A: 10.54.22.9` or `AAAA: 2a01:332::2`).

The value for complex types, such as `MX` is as per the standard zone file (eg. `MX: 10 mta.example.com`) At some point this will become parametrised.

## The Root object (`@`)
To refer to the base/root domain, use the `"@"` key:
```yaml
zones:
  example.com:
    "@":
      A: 10.54.22.9
      AAAA: 2a01:332::2
      MX:
        - 10 mta1.example.com
        - 10 mta2.example.com
```

## Aliases virtual type
There is a virtual record type `aliases` which is a list of names to CNAME to this record.

For example:

```yaml
zones:
  example.com:
    "@":
      A: 10.54.22.9
      aliases:
        - www
        - ftp
```
# Running
Invoke the docker container with the input yaml file:
```bash
docker run --rm -ti -v "${PWD}:/a" -w /a fooflington/mythic-dns mafoo.org.uk.yml
```

## Dry run
Pass the environment variable `DRY_RUN` to prevent any changes:

```bash
docker run --rm -ti -v "${PWD}:/a" -w /a -e DRY_RUN=1 fooflington/mythic-dns mafoo.org.uk.yml
```
