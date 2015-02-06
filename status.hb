{{#each hosts}}{{name}}
{{#each containers}}
  {{contid id}} {{contname status.Names.[0]}}{{#containerConfig}} (container {{../containerConfigName}}){{/containerConfig}}{{#proxyConfig}} (proxy){{/proxyConfig}}{{#websiteConfig}} (website {{../websiteConfigName}}){{/websiteConfig}}{{#proxyCorrect}}
    proxied ✓ ({{websiteHostname}}){{/proxyCorrect}}
    {{status.Status}}
{{/each}}
{{/each}}
