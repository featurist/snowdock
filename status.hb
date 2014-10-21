{{#hosts}}
{{#websites}}
{{name}} -> {{website.hostname}}

{{#containers}}
  {{host}}:{{port}} -> {{#publishedPorts}}{{port}} {{internalPort}}{{/publishedPorts}}
{{/containers}}
{{/websites}}
{{/hosts}}
