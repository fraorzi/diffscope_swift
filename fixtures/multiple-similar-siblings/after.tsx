export function CommandMenu() {
  return (
    <Menu>
      <Item icon="save" label="Save file" shortcut="Cmd S" />
      <Item icon="save" label="Save copy" shortcut="Cmd D" />
      <Item icon="open" label="Open file" shortcut="Cmd O" />
      <Item icon="quit" label="Quit app" shortcut="Cmd Q" />
    </Menu>
  );
}
