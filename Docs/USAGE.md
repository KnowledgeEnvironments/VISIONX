# Using UHF X11

## Start the Server

1. Launch UHF X11 on Apple Vision Pro.
2. Review the first-run network limitations notice.
3. Leave authentication set to MIT-MAGIC-COOKIE-1.
4. Start the X.Org server.
5. Note the address, display number, and `xauth` command shown by the app.

The default X11 display is `:0`, corresponding to TCP port 6000.

## Authorize a Client

On a trusted client machine, add the cookie displayed by UHF X11. This example uses an address reserved for documentation:

```sh
xauth add 192.0.2.42:0 MIT-MAGIC-COOKIE-1 <cookie-shown-by-the-app>
```

Replace the example address and cookie with the values displayed by the app. The cookie is a credential; do not paste it into issues, screenshots, or shared logs.

Launch an X11 client with:

```sh
DISPLAY=192.0.2.42:0 xterm
```

For clients that use libGL, force indirect rendering when testing experimental GLX:

```sh
DISPLAY=192.0.2.42:0 LIBGL_ALWAYS_INDIRECT=1 glxinfo -B
```

### Experimental GLX

The App Store build includes the experimental provider, but it is disabled by default. Stop the server, enable **Experimental GLX** in the app's Experimental settings, and start the server again. The toggle cannot be changed while the server is running.

When enabled, UHF X11 advertises GLX 1.3 with no GLX extension strings and implements a limited indirect OpenGL 1.1 fixed-function subset through Metal. Unsupported clients or commands may fail; disable the setting and restart the server to return to the 2D-only configuration.

## Window Behavior

Ordinary top-level X windows open as independent visionOS windows. UHF X11 forwards focus, pointer motion, primary-button input, scrolling, keyboard events, and close requests. Presentation settings affect only the native rendering surface and do not silently resize the X client.

The bundled bitmap fonts cover common classic X11 clients. Additional indexed bitmap-font directories can be imported from the app and take effect after a server restart.

## Troubleshooting

If a client cannot connect:

- Confirm the server is running and the client uses the address currently displayed by the app.
- Confirm the client can reach TCP port 6000 on the trusted local network.
- Re-run the displayed `xauth` command if the server cookie changed.
- Check that a firewall or VPN is not blocking the selected route.
- Verify that the client uses `DISPLAY=<address>:0`, not a local Unix socket.

If a classic application cannot find a font, inspect its requested XLFD and either choose a bundled family or import the matching indexed bitmap-font directory.

## Unsafe Testing Mode

`xhost +` accepts unauthenticated X11 clients. It exists for isolated smoke testing and should not be enabled on a shared network. Stop the server when testing is complete.

X11 traffic is not encrypted in either authentication mode. No security monitoring or vulnerability-response service is provided. See the repository [project disclaimer](../DISCLAIMER.md).
