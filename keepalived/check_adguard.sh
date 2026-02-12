#!/bin/bash
# Health check script for AdGuard Home
# Returns 0 if AdGuard is responding to DNS queries, non-zero otherwise

nslookup google.com 127.0.0.1 > /dev/null 2>&1
exit $?
