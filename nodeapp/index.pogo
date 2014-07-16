express = require 'express'
os = require 'os'
fs = require 'fs'

app = express()
app.engine('txt', require('ejs').renderFile)
app.use @(req, res)
  res.header 'content-type' 'application/json'
  res.send (JSON.stringify {
    host = os.hostname()
    url = req.url
    method = req.method
    headers = req.headers
    message = 'hi from nodeapp'
    version = parseInt (fs.readFile! 'version.txt' 'utf-8' ^)
  } (null, 2))

app.listen (process.env.NODE_PORT @or 80)
