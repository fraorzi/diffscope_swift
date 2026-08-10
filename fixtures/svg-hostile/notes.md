# svg-hostile

The control for the `<img>` boundary (DEC-063, extending DEC-028), not a nicety.

The file carries an `onload` handler, a `<script>` element, an `<image href>` to a host that does
not resolve and an `xlink:href` `<use>`. All four are things an SVG in a repository is allowed to
contain, and this product renders repository content.

**The rule is that the pane draws it and runs none of it.** The bytes reach the page as a `data:`
URL in an `<img>` element, where script does not execute and the renderer's CSP refuses the remote
loads regardless. The two sides differ only in the marker each would set if it ever ran, so a
failure of the boundary is observable rather than theoretical: `globalThis.__diffscopeHostile`
must not exist after the comparison is drawn.

The visible cost of the rule is recorded in `24-design-contract.md` §3: nothing can style the
inside of an SVG, so the transparency checkerboard sits behind it rather than being composed into
it.
