"""Open-data Amsterdam -> detailed game-ready buildings.

Pipeline: 3D BAG CityJSON (or an OBJ export from 3d.amsterdam.nl) gives each
building's true footprint, height and roof. We keep that as the skeleton and
replace every exposed wall with a procedurally detailed Amsterdam facade
(windows with reveals, frames and glazing bars, doors with stoops, shopfronts,
cornices, and step/neck/bell/spout gables), then write one glTF binary.
"""
