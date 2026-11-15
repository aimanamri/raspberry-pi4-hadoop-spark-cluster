# Cluster scripts

Bash scripts that do the steps of the [main guide](../README.md). The guide stays the reference. Use the scripts when you want to save time or repeat the build.

All scripts read their settings from one file, `scripts/.env`. Names, IP addresses, versions and memory sizes are there. You do not edit the scripts.

## Supported systems

| OS | Java 17 source |
| --- | --- |
| Raspberry Pi OS 64-bit, Bookworm | apt (`openjdk-17-jdk`) |
| Raspberry Pi OS 64-bit, Trixie | SDKMAN (Trixie has no Java 17 package) |
| Ubuntu Server 64-bit, 22.04 and 24.04 | apt (`openjdk-17-jdk`) |
| Debian 64-bit | apt if the package exists, if not SDKMAN |

`setup-node.sh` finds the OS in `/etc/os-release` and chooses the method. It stops with a message on a 32-bit OS or on an OS that is not based on Debian.

## Quick start

1. **On your computer or on each Pi**, get the repository and set your values:
   ```bash
   git clone https://github.com/aimanamri/raspberry-pi4-hadoop-spark-cluster.git
   cd raspberry-pi4-hadoop-spark-cluster
   cp scripts/.env.example scripts/.env
   nano scripts/.env
   ```
   Use the **same** `scripts/.env` on every Pi.

2. **On every Pi** (master and workers), run:
   ```bash
   sudo ./scripts/setup-node.sh
   ```
   If the host name of the Pi is not in `NODES`, add `--hostname pi2` (use the right name). Set a password for the `hadoop` user when the script asks. Restart the Pi if the script says so.

3. **On the master Pi only**, change to the `hadoop` user and get the repository again in its home folder. Copy `scripts/.env` too.
   ```bash
   sudo -iu hadoop
   git clone https://github.com/aimanamri/raspberry-pi4-hadoop-spark-cluster.git
   cd raspberry-pi4-hadoop-spark-cluster
   ```
   Then run all master steps:
   ```bash
   ./scripts/install-all.sh
   ```
   You can also run the steps one by one (see the table below).

## The scripts

| Script | Run on | As | Guide part | What it does |
| --- | --- | --- | --- | --- |
| `setup-node.sh` | every Pi | root (`sudo`) | 1.4 to 1.7, 2 | Updates packages, sets the host name and `/etc/hosts`, creates the `hadoop` user, installs Java 17 |
| `setup-ssh.sh` | master | `hadoop` | 1.8 | Creates the SSH key and aliases, copies the key to all nodes |
| `install-hadoop.sh` | master | `hadoop` | 3 | Downloads Hadoop, writes the config files, copies everything to the workers |
| `install-spark.sh` | master | `hadoop` | 5 | Downloads Spark, writes `spark-defaults.conf` |
| `start-cluster.sh` | master | `hadoop` | 4, 5.4 | Formats HDFS (first time only), starts HDFS, YARN and the History Server. Use `--stop` to stop. |
| `verify.sh` | master | `hadoop` | 7 | Checks Java, Hadoop, HDFS, YARN and Spark. Prints PASS or FAIL for each check. |
| `install-all.sh` | master | `hadoop` | 1.8 to 7 | Runs the five master scripts in order |

All scripts accept `--help`. Most accept `--dry-run` (show what the script would do). Every script can run again safely.

## Settings in `scripts/.env`

| Setting | Default | Meaning |
| --- | --- | --- |
| `NODES` | `pi1=192.168.35.11 pi2=192.168.35.12 pi3=192.168.35.13` | Name and IP address of each node. Add or remove nodes here. |
| `MASTER_HOST` | `pi1` | The master node. All other nodes are workers. |
| `HADOOP_USER` | `hadoop` | Linux user for Hadoop and Spark |
| `HADOOP_VERSION` | `3.5.0` | Hadoop version |
| `SPARK_VERSION` | `4.3.0` | Spark version |
| `JAVA_VERSION` | `17` | Java version |
| `JAVA_METHOD` | `auto` | `auto`, `apt` or `sdkman` |
| `SDKMAN_JAVA_IDENTIFIER` | empty | SDKMAN build, for example `17.0.13-tem`. Empty means the newest Temurin build. |
| `HDFS_REPLICATION` | `1` | Copies of each HDFS block. Not more than the number of workers. |
| `HDFS_PORT` | `9000` | NameNode port |
| `HDFS_DATA_DIR` | `/home/hadoop/hdfs` | HDFS data folder |
| `YARN_NODE_MEMORY_MB` | `1536` | Memory that YARN can use on each node |
| `YARN_MAX_ALLOCATION_MB`, `YARN_MIN_ALLOCATION_MB` | `1536`, `128` | Largest and smallest container |
| `MAPRED_AM_MEMORY_MB`, `MAPRED_MAP_MEMORY_MB`, `MAPRED_REDUCE_MEMORY_MB` | `512`, `256`, `256` | MapReduce memory |
| `SPARK_DRIVER_MEMORY`, `SPARK_AM_MEMORY`, `SPARK_EXECUTOR_MEMORY` | `512m` | Spark memory |
| `SPARK_HISTORY_PORT` | `18080` | Spark History Server port |
| `SPARK_LOG_DIR_HDFS` | `/spark-logs` | Spark event log folder in HDFS |
| `VERIFY_QUEUE` | `dev` | YARN queue for the SparkPi check |
| `*_DOWNLOAD_BASE`, `*_ARCHIVE_BASE` | Apache mirrors | Download addresses. The scripts try the archive when the main address does not have the file. |

After you change a value, run the matching script again (for example `install-hadoop.sh`), then restart the cluster with `start-cluster.sh --stop` and `start-cluster.sh`.

## What the scripts do not do

- They do **not** set a static IP address. Set the addresses on your router (guide 1.5).
- They do **not** write the OS to the SD card or set Wi-Fi. Use the Raspberry Pi Imager (guide 1.2 and 1.3).
- The queue sizes (`prod` 70%, `dev` 30%) come from `config_files/capacity-scheduler.xml`. Edit that file to change them.
- Use the **same Java method on every node**. The Java path must be the same on all nodes, because Hadoop and Spark use one `JAVA_HOME` path.

## What was tested

- The scripts ran from start to end in three Ubuntu 24.04 arm64 containers (`pi1` master, `pi2` and `pi3` workers). All 12 checks of `verify.sh` passed, including the Hadoop `pi` example and SparkPi on YARN. A second run of the node, SSH and install scripts also worked.
- `setup-node.sh` also ran on Debian Bookworm (Java 17 from apt) and Debian Trixie (Java 17 from SDKMAN).
- Not tested: real Raspberry Pi hardware, Raspberry Pi OS detection, Ubuntu 22.04, and the static IP and SD card steps (the scripts do not do those).

## Safety

- `setup-node.sh` changes `/etc/hosts`, the host name and the packages. It removes the `127.0.1.1` line, so that Hadoop does not listen on the loopback address only.
- `start-cluster.sh --reformat` deletes all HDFS data. It asks you to type `YES`.
- Downloads are checked against the SHA-512 file from Apache. The script stops if the checksum is different.
