argv = (require 'minimist') (process.argv.slice 2)
docker = (require './docker') {
  apiUrl = 'http://centos:8000/api/v1/'
  apiKey = 'admin:3b2534ceeb8e776c14300687587aad2f5a808576'
}

/*
docker.application! {
  domain_name = 'myapp2.linux'
  containers = docker.4 containersFromImage '192.168.50.4:5000/nodeapp'!
}
*/

docker.image 'ubuntu'!
