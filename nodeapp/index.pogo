express = require 'express'
os = require 'os'

app = express()
app.engine('txt', require('ejs').renderFile)

app.get '/' @(req, res)
  res.header 'content-type' 'text/plain'
  res.render 'index.txt' {host = os.hostname()}

app.listen (process.env.NODE_PORT @or 80)
