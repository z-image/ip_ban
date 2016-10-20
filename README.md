# Toy system for blacklisting IPs on a server farm

As of 20 Oct 2016 this is an alpha quality release.

## Introduction

This is essentially a task queue with distributed workers. Quite a bit of effort has gone into making sure no task is ever lost.

The system has the following components:

 * API
  - CLI, HTTP (not yet ready).
 * Database (MySQL / InnoDB)
  - Servers: end systems on which iptables is run.
  - Groups of servers (e.g. @all, @europe, @equinix-dc1, @web-servers).
  - Networks to be banned (e.g. 1.2.3.4/32, 4.3.2.128/30, 10.0.0.0/8).
  - Bans: brings together Networks & Groups/Servers.
  	- Bans have expiration, handled by cronjob (default is "never").
  - Queue: the individual chunks of work - one row per Network/Server tuple.
  	- For example if @all contains 1000 servers and we ban 1.1.1.1/32 on @all - 1000 rows will be inserted in the Queue, each with individual status, retry timer etc.
	- Most tables contain additional meta info like time of creation, last update or worker's pid (premature optimization … evil).
 * Job server (Gearman)
  - Tasks are sent to workers (which can live on multiple servers).
  - Workers employ the Queue table in the Database to mark their progress, reschedule tasks etc.

## Requirements

  * DB server
   - MySQL server (InnoDB storage engine)
  * Worker server(s)
   - bash
   - MySQL CLI
   - Gearman CLI
   - SSH client
  * API server
   - DBD::mysql & Gearman::Client perl modules
  * Hosts
   - SSH server
   - iptables

## Installation

 * DB server
  - `apt-get install mysql-server`
  - _GRANT ALL ON ip_ban.* TO 'ip-ban-api'@'localhost' IDENTIFIED BY 'some_pass'_
  	- Replace _'localhost'_ with hosts/ips of the API (where perl code lives) and and workers hosts.
  	- Load DB schema: `mysql -u ip-ban-api -p < ip_ban.sql`
 * API server
  - `apt-get install libdbd-mysql-perl`
 * Worker's server(s)
  - `apt-get install mysql-client gearman-tools openssh-client`
 * Hosts
  - `apt-get install openssh-server iptables`

## Demo transcript


```
laptop$ ip-ban-cli --help

Usage:  ip-ban-cli <command> [options]

<command> is one of: ban, unban, runq, summary, list, count

ban/unban options:
        --subnet (single IP is /32)
        --target list of servers to apply ban (default: @all)
        --ttl    how many seconds to keep the ban (not yet implemented)
list/count options:
        --queue
        --failed

Example:  ip-ban-cli ban --subnet 10.9.8.7/32 --target s101.example.com

```

```
laptop$ ./ip-ban-cli ban --target @all --subnet 10.0.10.128/30

laptop$ ./ip-ban-cli list
   id              subnet              target              expires              updated              created
    1      10.0.10.128/30                @all                never  2016-10-20 14:06:56  2016-10-20 14:06:56

laptop$ ./ip-ban-cli list --queue
   id              subnet              target    task  status              updated              created   retry
    1      10.0.10.128/30    s101.example.com     ban       F  2016-10-20 14:06:58  2016-10-20 14:06:56      60
    9      10.0.10.128/30    s109.example.com     ban       R  2016-10-20 14:06:58  2016-10-20 14:06:56      0
   10      10.0.10.128/30    s110.example.com     ban       N  2016-10-20 14:06:58  2016-10-20 14:06:56      0
```

## Benchmark

Start from clean DB. Insert 10000 servers in group @all.
```
db$ mysql -u ip-ban-api -p ip_ban < ip_ban.sql

db$ for i in {1..10000}; do  printf "INSERT INTO ip_ban.servers SET hostname='s%05d.example.com'\n" $i |mysql --defaults-file=ip-ban-worker-mysql.cnf --user=ip-ban-api ;done

db$ echo "INSERT INTO groups SET name='@all'" |mysql --defaults-file=ip-ban-worker-mysql.cnf --user=ip-ban-api

db$ for i in {11..10010}; do  echo "INSERT INTO ip_ban.servers_groups SET group_id=12, server_id=$i" |mysql --defaults-file=ip-ban-worker-mysql.cnf --user=ip-ban-api ;done
```

Prepare SSH known_hosts @ the (single) workers' server:
```
workers$ time for i in {1..10000}; do  ssh -oStrictHostKeyChecking=no $(printf "s%05d.example.com" $i) true  ;done
real    29m35.128s
user    10m47.888s
sys     0m35.236s
```

```
laptop$ time ./ip-ban-cli ban --target @all --subnet 1.1.1.1/32
real    0m8.128s

laptop$ ./ip-ban-cli list
   id              subnet              target              expires              updated              created
    1          1.1.1.1/32                @all                never  2016-10-20 15:28:13  2016-10-20 15:28:13

laptop$ time ./ip-ban-cli list --queue |wc -l
10001

real    0m0.255s
```

Because workers are written in bash & use ssh that part takes a lot of time of course. Well, it depends on how many worker servers you have to spread the load.
