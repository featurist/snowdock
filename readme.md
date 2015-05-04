# Snowdock

Snowdock is a docker deployment utility, with special support for hot-swapping updates to websites.

## Hot Swap Deployment

Under the hood it uses [hipache](...) to proxy requests to several backend docker containers. Hipache allows us to dynamically route HTTP traffic to several website backends. This means that during deployment we can deploy the new version of the website alongside the old version, then turn off the old version.

## Host Environment

You just need Docker running on your host environment for this to work. Docker should be accessible via a TCP/HTTP port however. This can be configured by adding a `-H 127.0.0.1:2375` to your docker startup options.

On Ubuntu, in the `/etc/default/docker` file, you should see something like this:

    DOCKER_OPTS="-r=true ${DOCKER_OPTS} -H tcp://127.0.0.1:2375 -H unix:///var/run/docker.sock"

On RHEL or Centos, in the `/etc/sysconfig/docker` file you should see the something like this:

    OPTIONS=--selinux-enabled -H fd:// -H 127.0.0.1:2375

## SSH

Snowdock can use SSH to access the host, meaning you don't need to expose the docker port to run deployments.


# Instructions

Install snowdock:

```shell
npm install snowdock --save-dev
```

Create a file `snowdock.json`

# Adding a host
You need at least one host to deploy to, this can be localhost for development/testing purposes

The host configuration consits of
## docker
The name of the docker host and the port docker is listenting on

## redis
The name of the redis host and the port redis is listenting on

## internalIp
This is the IP address for docker0 interface, it defaults to 172.17.42.1, though in snowdock you still have to specify it.

## ssh
This is an optional section that specifies the ssh user when connecting to remote hosts

Here is a full example of a host configuration

    {
      "localhost": {
        "docker": {
          "host": "localhost",
          "port": 2375
        },
        "redis": {
          "host": "localhost",
          "port": 6379
        },
        "internalIp": "172.17.42.1",
        "ssh": {
          "user": "sshuser"
        }
      }
    }

# Adding a website
You will probably want to have at least one website for snowdock to host
## nodes
The number of instances of this website to run.

For example if you specify 1 a single container will be started, specifying 2 will start 2 containers and so on.

## hostname
The host name of th website for example `myapp.com`

## container
Each website is hosted inside a container, this is where you configure it.

### image
The name of the docker image, this either needs to be in the public repo or available on each host

### publish
The port number ....

### env
Environment variables to be passed to each container
you can use shell-like variables to pass environment
variables from the parent process

For example (see $password)

    "DB_URL": "postgres://username:$password@localhost/database"

### volumes
An array of volumes to mount

mount `/path` from the host into `/path` in the container

    /path

mount `/host/path` from the host into `/container/path` in the container read-write

    /host/path:/container/path:rw

mount `/host/path` from the host into `/container/path` in the container readonly

    /host/path:/container/path:ro

### Volumes From

An array of container names to mount volumes from. Names can be optionally followed by `:ro` or `:rw`, to specify readonly or readwrite. See [Docker Volumes](https://docs.docker.com/userguide/dockervolumes/).

    "volumesFrom": ["redisdb-data"]

### links
An array of links. Each link is of the form `container:alias`, and produces several environment variables in the container starting with `alias`. See [Linking Containers Together](https://docs.docker.com/userguide/dockerlinks/).

E.g.

    "links": ["redisdb:redis"]

### privileged
Run the container with root privileges, this can be `true`, `false` or `undefined`

### command

The command to run on the container one start. (This is the last argument to the `docker run` command.)

Here is a full example of a website configuration

    {
      "myapp": {
        "nodes": 4,
        "hostname": "myapp.com",
        "container": {
          "image": "username/myapp",
          "publish": ["4000"],
          "env": {
            "DB_URL": "postgres://username:$password@localhost/database"
          }
          volumes: [
            '/path',
            '/host/path:/container/path:rw,
            '/host/path:/container/path:ro'
          ]
        }
      }
    }

# The proxy
All requests come through the hipache proxy. You need to expose this on port 80, you also need to expose the redis port so the configuration can propogate

Here is a full example of a typical proxy configuration

    {
      "proxy": {
        "publish": ["8000:80", "6379:6379"]
      }
    }

# Other containers
You can add other general purpose containers, for example you may want to add a database or a worker process.

## image
The name of the docker image

## net
The type of networking to use (as per [docker options][https://docs.docker.com/reference/run/#network-settings]

## other options
All other options that you can set on a website/container are also applicable here

Here is a full example of adding a postgres database

    {
      "postgres": {
        "image": "postgres",
        "net": "host"
      }
    }

# Commands
Once you have a configuration file you will want to start up the cluster

First of all start the proxy

```shell
snowdock start proxy
```

The first time your run this it will pull down the docker image `library/hipache` which will take some time.

Once this has been retrieved it will then start the container

You will then want to start your website

`snowdock start website myapp`

And finally any other containers you have specified

`snowdock start postgres`

## Full Configuration

The configuration file has the following format:

    {
      "hosts": {
        "host-1": {
          "docker": {
            "host": "host-1",
            "port": 2375
          },
          "redis": {                   // the redis DB to store details of
                                       // running websites
            "host": "host-1",
            "port": 6379
          },
          "internalIp": "172.17.42.1", // the IP address for the docker0 interface

          "ssh": {                     // optional, set if you want
                                       // to connect via SSH
            "user": "sshuser"          // the user to use
          }
        }
      },
      "websites": {
        "myapp": {
          "nodes": 4,                  // number of nodes to run
          "hostname": "myapp.com",           // the hostname for the website
                                       // 
          "container": {
            "image": "username/myapp",
            // which ports to listen on
            "publish": ["4000"],
            "env": {
              // environment variables to be passed to each container
              // you can use shell-like variables to pass environment
              // variables from the parent process
              // see $password
              "DB_URL": "postgres://username:$password@localhost/database"
            },
            // volumes
            "volumes": [
              // mount /path from the host into /path in the container
              '/path',
              // mount /host/path from the host into /container/path in the container
              // read-write
              '/host/path:/container/path:rw,
              // mount /host/path from the host into /container/path in the container
              // readonly
              '/host/path:/container/path:ro'
            ],
            // privileged option: true|false|undefined
            "privileged": true
          }
        },
        "proxy": {
          // container details for the hipache proxy to use
          "publish": ["8000:80", "6379:6379"]
        }
      },
      "containers": {
        // other containers, which can be started and stopped independently
        "nginx": {
          "image": "username/nginx",
          "net": "host"
        }
      }
    }
