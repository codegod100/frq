"""Generated stub -- the container is defined by container.toml.

Edit container.toml, not this file.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from _loader import Container  # noqa: E402

c = Container.from_toml(__file__)
image, app = c.image, c.app

# A web container's Function is not vestigial the way a sandbox's is: it *is*
# the container. Registered at import time so that `modal deploy` finds it,
# and so that the re-import inside the container binds the same body.
serve = c.register_web()
