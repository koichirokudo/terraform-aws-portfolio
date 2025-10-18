#!/bin/bash

sudo dnf install -y docker
sudo systemctl start docker
sudo systemctl enable docker
