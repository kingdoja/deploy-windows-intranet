# Shared Intranet Gateway and DNS

Use this reference when one Windows host serves multiple intranet websites.

## Recommended topology

Keep each application's generated Caddy on a unique stable high port and give it a unique loopback admin port. Put one separately owned Caddy on ports 80/443 and route by hostname:

```text
app-a.corp.example -> shared gateway -> 127.0.0.1:8080
app-b.corp.example -> shared gateway -> 127.0.0.1:8081
```

Prefer hostnames over `/app-name` prefixes. Subpaths frequently break cookies, redirects, absolute URLs, Next.js assets, and OAuth callbacks unless the application was designed with a base path.

## Ownership rules

- Treat the shared gateway as infrastructure with one owner. Do not let per-project release scripts rewrite its complete Caddyfile.
- Have the gateway Caddyfile import a route directory inside its HTTP server block, for example `import C:/ProgramData/IntranetGateway/routes/*.caddy`.
- Persist that import in the gateway owner's source generator; otherwise its next deployment will erase every shared route.
- Give every Caddy process a distinct `caddyAdminPort`. The default 2019 collides when multiple Caddy services run on one host.
- Use `configure-shared-gateway.ps1` only after the user authorizes modification of the shared gateway. Run it without `-Apply` first.

Example route fragment:

```caddyfile
@catalog host catalog.corp.example
handle @catalog {
    reverse_proxy 127.0.0.1:8080
}
```

Validate and reload through the gateway's own admin address, then verify both the new hostname and an existing site. Keep a recoverable backup of the prior route/configuration.

## DNS

- Request an internal DNS A record from the corporate DNS owner, for example `catalog.corp.example A 10.0.0.10`.
- Server routing does not make DNS resolve. Until the A record exists, the formal hostname will fail for other users.
- A wildcard resolver such as `sslip.io` can provide a temporary alias when corporate clients allow external DNS, but it creates an external DNS dependency. Do not present it as the long-term corporate name.
- Reserve the host IP through DHCP or use a managed static address before publishing stable DNS.
- Avoid editing every user's hosts file; it does not scale and is easy to forget during migration.
