# Wearable protocol trace v1

A trace is a bounded, ordered synthetic sequence of production envelope shapes. All fields are required and no defaults apply. The trace validator returns typed errors with safe paths for installation/device/recording/epoch/correlation changes, non-monotonic revision, invalid replay after terminal outcomes, missing transfer/ACK prerequisites, deletion before correlated vault commit, and incorrect declared final/deletion state. Trace fixtures do not constitute physical-device evidence.
