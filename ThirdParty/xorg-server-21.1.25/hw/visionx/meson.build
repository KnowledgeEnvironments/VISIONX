visionx_bridge_inc = include_directories('../../../../Sources/CXOrgBridge/include')

visionx_ddx_srcs = [
    'InitInput.c',
    'InitOutput.c',
    'VisionXGLX.c',
    '../../mi/miinitext.c',
    '../../mi/miinitext.h',
]

visionx_executable_srcs = visionx_ddx_srcs + [
    '../../../../Sources/CXOrgBridge/visionx_ddx.c',
]

visionx_server = executable(
    'Xvisionx',
    visionx_executable_srcs,
    include_directories: [inc, visionx_bridge_inc],
    dependencies: common_dep,
    c_args: ['-DVISIONX_ENABLE_EMBEDDED_XORG', '-DVISIONX_GLX_PROVIDER'],
    link_with: [
        libxserver_main,
        libxserver_fb,
        libxserver,
        libxlibc,
        libxserver_xkb_stubs,
        libxserver_xi_stubs,
    ],
    install: false,
)

visionx_embedded_backend = static_library(
    'visionx_xorg_backend',
    visionx_ddx_srcs,
    include_directories: [inc, visionx_bridge_inc],
    dependencies: common_dep,
    c_args: ['-DVISIONX_GLX_PROVIDER'],
    link_whole: [
        libxserver_fb,
        libxserver,
        libxlibc,
        libxserver_xkb_stubs,
        libxserver_xi_stubs,
    ],
    install: false,
)
