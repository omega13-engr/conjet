"""Run the pinned Docker Python SDK against the lane's private Unix socket."""

import json
import sys

import docker


def main():
    endpoint, container, *commands = sys.argv[1:]
    if docker.__version__ != '7.1.0':
        raise RuntimeError('fixture requires docker==7.1.0')
    results = []
    with docker.APIClient(base_url=endpoint, version='1.44', timeout=8) as client:
        for command in commands:
            identifier = client.exec_create(container, ['/bin/sh', '-c', command])['Id']
            stdout, stderr = client.exec_start(identifier, demux=True)
            inspected = client.exec_inspect(identifier)
            if inspected['Running'] is not False or type(inspected['ExitCode']) is not int:
                raise RuntimeError('exec stream ended before an integer terminal exit status')
            results.append({'exit': inspected['ExitCode'], 'stdout': stdout.decode(),
                            'stderr': stderr.decode()})
    print(json.dumps(results))


if __name__ == '__main__':
    main()
