# Incoming models

Drop new character models here (the model file, `.glb` / `.gltf` / `.fbx`, plus
any texture folder and licence file that came with it), then commit and push:

    git add godot-city/models/incoming
    git commit -m "Add the new character models"
    git push

They are converted into `models/` from here (sized, textures shrunk for the
web build) and wired into the game.
