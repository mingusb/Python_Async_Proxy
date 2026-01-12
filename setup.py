import os

from setuptools import Extension, setup
from Cython.Build import cythonize

extra_compile_args = [
    "-O3",
    "-Ofast",
    "-march=native",
    "-flto",
    "-fno-semantic-interposition",
    "-fvisibility=hidden",
]
if os.environ.get("AVX512", "0") == "1":
    extra_compile_args.append("-mavx512f")

ext = Extension(
    "proxy",
    ["proxy.pyx"],
    extra_compile_args=extra_compile_args,
    extra_link_args=["-flto"],
    define_macros=[
        ("CYTHON_CLINE_IN_TRACEBACK", 0),
        ("CYTHON_FAST_PYCALL", 1),
        ("CYTHON_USE_PYINT_INTERNALS", 1),
    ],
)

setup(
    ext_modules=cythonize(
        ext,
        language_level="3",
        compiler_directives={
            "boundscheck": False,
            "wraparound": False,
            "cdivision": True,
            "infer_types": True,
            "nonecheck": False,
            "initializedcheck": False,
        },
    )
)
