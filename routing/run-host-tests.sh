#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p test-results
xcrun clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror \
    -framework Foundation options-host-tests.mm -o test-results/options-host-tests
test-results/options-host-tests
xcrun clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror \
    -framework Foundation -framework CoreGraphics \
    backboard-host-tests.mm -o test-results/backboard-host-tests
test-results/backboard-host-tests
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -pthread \
    sidebar-scope-host-test.cpp -o test-results/sidebar-scope-host-tests
test-results/sidebar-scope-host-tests
xcrun clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror \
    -framework Foundation menu-host-tests.mm -o test-results/menu-host-tests
test-results/menu-host-tests
