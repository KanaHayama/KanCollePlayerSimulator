#! /usr/bin/env python3
# -*- coding:utf-8 -*-

from sys import argv, stderr
import os
from urllib import request
import time
    
def main():
    port = argv[1] if len(argv) > 1 else None
    delay = argv[2] if len(argv) > 2 else None
    if port is None or delay is None:
        port = input("Port:")
        delay = input("Delay(s):")
    for i in range(int(delay), 0 , -1):
        print("count down: %i" % i)
        time.sleep(1)

    response = request.urlopen("http://localhost:%s/capture?format=png" % port)
    filename = "Capture_" + time.strftime("%Y-%m-%d-%H_%M_%S",time.localtime(time.time())) + ".png"
    with open(filename, "wb") as f:
        f.write(response.read())
    print("Save captured picture as %s" % filename)

if __name__ == "__main__":
    main()
