express = require 'express'
os = require 'os'

app = express()

app.get '/' @(req, res)
  res.end "hi from #(os.hostname())\n"

app.listen 80
