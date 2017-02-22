#! /bin/bash

# Test the connection, wait if needed.
while [[ $(ping -c1 google.com 2>&1 | grep " 0% packet loss") == "" ]]; do
  echo "[LoRa Box]: Waiting for internet connection..."
  sleep 30
  done

# Fire up the forwarder.
./lora_pkt_fwd
