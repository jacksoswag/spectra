#!/bin/bash
# build.sh delegates to install.sh so every build path is prompt-free: stable
# yabai-cert signing keeps the TCC designated requirement constant, and install.sh
# pre-grants Screen Recording before launch. Use either name; they do the same thing.
#
#   bash Scripts/build.sh            # Debug
#   bash Scripts/build.sh Release    # optimized
exec bash "$(dirname "$0")/install.sh" "$@"
