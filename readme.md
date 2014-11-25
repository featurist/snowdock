## Snowdock

Snowdock is a docker deployment utility, with special support for hot-swapping updates to websites.

### Hot Swap Deployment

Under the hood it uses [hipache](...) to proxy requests to several backend docker containers. Hipache allows us to dynamically route HTTP traffic to several website backends. This means that during deployment we can deploy the new version of the website alongside the old version, then turn off the old version.

### Host Environment

You just need Docker running on your host environment for this to work. Docker should be accessible via a TCP/HTTP port however. This can be configured by adding a `-H 127.0.0.1:2375` to your docker startup options.

On Ubuntu, in the `/etc/default/docker` file, you should see something like this:

    DOCKER_OPTS="-r=true ${DOCKER_OPTS} -H tcp://127.0.0.1:2375 -H unix:///var/run/docker.sock"

On RHEL or Centos, in the `/etc/sysconfig/docker` file you should see the something like this:

    OPTIONS=--selinux-enabled -H fd:// -H 127.0.0.1:2375

### SSH

Snowdock can use SSH to access the host, meaning you don't need to expose the docker port to run deployments.

## Configuration

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
            volumes: [
              // mount /path from the host into /path in the container
              '/path',
              // mount /host/path from the host into /container/path in the container
              // read-write
              '/host/path:/container/path:rw,
              // mount /host/path from the host into /container/path in the container
              // readonly
              '/host/path:/container/path:ro'
            ]
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
