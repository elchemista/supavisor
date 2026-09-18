# Supavisor integration

Source: https://github.com/elchemista/ex_fastembed
Revision: fa991c970c310b2f44f837062fe9202d71f96311
License: Apache-2.0 (see LICENSE).

Local additions: `unload/0`, required file names in model discovery, and the
effective cache directory. These support real native model unloading and correct
variant sizes in the dashboard. Native builds are required: upstream 0.1.0
precompiled artifacts do not contain these added NIFs. No model weights are
included. The original library repository has not been modified or published.
