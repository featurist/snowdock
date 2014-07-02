fs = require 'fs'

module.exports () =
  vagrantFile = "#(__dirname)/Vagrantfile"
  vagrant = fs.readFile (vagrantFile) 'utf-8' ^!
  re = r/private_network.*ip:\s*['"](\d+\.\d+\.\d+\.\d+)/
  match = re.exec (vagrant)
  if (match)
    match.1
  else
    @throw @new Error "could not find private network ip in #(vagrantFile)"
