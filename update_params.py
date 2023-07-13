#!/usr/bin/env python3

import json

def getpaths(d):
    if not isinstance(d, dict):
        yield [d]
    else:
        yield from ([k] + w for k, v in d.items() for w in getpaths(v))

# Load the old system parameters
with open("old-xoss-system-parameters.json", "r") as f:
    old_params = json.load(f)

# Load the new system parameters
with open("xoss-system-parameters.json", "r") as f:
    new_params = json.load(f)

# Get the old variables as a path and a respective value
old_vars = list(getpaths(old_params))

# Preserve values of the old variables
while len(old_vars) > 0:
    # Get the next variable in the list
    var  = old_vars.pop(0)
    path = var[:-1]
    value = var[-1]

    # Get a reference to the new system parameters data structure
    ref = new_params

    while len(path) > 1:
        try:
            # Step into the nested structure and update the reference
            ref = ref[path.pop(0)]
        except:
            # The variable does not exist, continue with the next one
            ref = None
            break

    if ref is None:
        continue
    else:
        try:
            # Set the value of the variable in the new parameters from the old parameters data structure
            ref[path.pop(0)] = value
        except:
            pass

# Generate the updated system parameters file
with open("new-xoss-system-parameters.json", "w") as f:
    json.dump(new_params, f, indent=4, separators=(',', ' : '))
