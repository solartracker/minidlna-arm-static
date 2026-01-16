#!/bin/sh

# 1. Download correct raw files
wget -O config.sub https://git.savannah.gnu.org/cgit/config.git/plain/config.sub
wget -O config.guess https://git.savannah.gnu.org/cgit/config.git/plain/config.guess

# 2. Make executable
chmod +x config.sub config.guess

