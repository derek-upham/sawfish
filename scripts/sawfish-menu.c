#include <gtk/gtk.h>
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

//
// Valid GAction names regexp: ^[A-Za-z0-9.-]+$
// per https://docs.gtk.org/gio/type_func.Action.name_is_valid.html
//
// GtkBuilder menu XML can declare accelerators. Use the
// "accelerator" attribute on menu items or the element;
// accelerator names follow Gtk accelerator string syntax
// (e.g., "n", "F1", "X").
//
// https://docs.gtk.org/gtk4/func.accelerator_parse.html
// https://docs.gtk.org/gdk4/func.keyval_from_name.html
// https://gitlab.gnome.org/GNOME/gtk/-/blob/main/gdk/gdkkeysyms.h
// https://valadoc.org/gdk-3.0/Gdk.ModifierIntent.html
//             <item>
//               <attribute name="label">_New</attribute>
//               <attribute name="action">app.new</attribute>
//               <attribute name="accel">&lt;Primary&gt;N</attribute>
//             </item>
// Primary is a symbolic modifier in GTK accelerator strings that maps to the platform's primary modifier key — typically:
//
//     Control (Ctrl) on Windows and Linux
//     Command (⌘) on macOS

// Docs on the menu XML format:
//
// https://docs.gtk.org///gtk4/class.PopoverMenu.html#menu-models
// https://wiki.gnome.org/Projects/GLib/GApplication/GMenuModel
// https://github.com/ToshioCP/Gtk4-tutorial/blob/main/gfm/sec18.md
//

const int HIDDEN_WINDOW_WIDTH = 1;
const int HIDDEN_WINDOW_HEIGHT = 1;

static const char *menu_file = NULL;

typedef void (*BuilderLoader) (GtkBuilder *);
BuilderLoader builder_loader = NULL;

void
builder_load_from_file (GtkBuilder *builder)
{
  if (menu_file)
    {
      /* Load menu from XML */
      GError *err = NULL;
      if (!gtk_builder_add_from_file (builder, menu_file, &err))
	{
	  fprintf (stderr, "loading menu failed: %s\n", err->message);
	  g_error_free (err);
	}
    }
}

void
builder_load_from_stdin (GtkBuilder *builder)
{
  /* Read all of stdin into a string */
  GString *buf = g_string_new (NULL);
  char chunk[4096];
  size_t n;
  while ((n = fread (chunk, 1, sizeof (chunk), stdin)) > 0)
    {
      g_string_append_len (buf, chunk, n);
    }

  GError *err = NULL;
  if (!gtk_builder_add_from_string (builder, buf->str, buf->len, &err))
    {
      fprintf (stderr, "loading menu failed: %s\n", err->message);
      g_error_free (err);
    }

  g_string_free (buf, TRUE);
}

/*
  Global, singleton state
*/

static GtkApplication *app = NULL;
static GtkWidget *popoverWidget = NULL;
static GtkWidget *window = NULL;
static gboolean action_fired = FALSE;

/*
  We identify "normal" items by their action, after stripping off the
  "app." prefix that the XML requires.

  We identify "checkbox" items by their stripped action as well.  Officially,
  we should connect the "change-state" signal to a callback, and have that
  receive the new checkbox true/false state.  But the menu closes down
  immediately, so we have no reason to update.  Intercept in "activate",
  and never let the "activate" chain call "change-stage".

  We identify "radio button" items by their *target*.  The common action
  defines the radio button group.  That's the one case where the
  "activated" callback parameter is not-null.  Again, we don't need to
  change state.
*/
static void
on_action_activated (GSimpleAction *action, GVariant *parameter, gpointer app)
{
  if (parameter)
    {
      if (g_variant_is_of_type(parameter, G_VARIANT_TYPE_STRING)) {
        const gchar *s = g_variant_get_string(parameter, NULL);
        if (s)
          {
            printf("%s\n", s);
          }
        else
          {
            fprintf (stderr, "XML menu has non-string target?!?\n");
          }
      }
    }
  else
    {
      const char *name = g_action_get_name (G_ACTION (action));
      printf ("%s\n", name);
    }

  action_fired = TRUE;
  g_application_quit (G_APPLICATION (app));
}

static void
on_popover_closed (GtkPopover *pop, gpointer app)
{
  if (! action_fired)
    {
      g_application_quit (G_APPLICATION (app));
    }
}

static void
set_window_type_popup (GtkWindow *win)
{
  GdkSurface *surface = gtk_native_get_surface (GTK_NATIVE (win));

  gdk_x11_surface_set_skip_pager_hint (surface, TRUE);
  gdk_x11_surface_set_skip_taskbar_hint (surface, TRUE);

#if 0
  /*
    This window type configuration looks like it's unimportant, but
    I'm keeping the old code around for now.
   */

  // Sawfish knows about these (wm/ext/match-window.jl):
  //
  // - _NET_WM_WINDOW_TYPE_NORMAL
  // - _NET_WM_WINDOW_TYPE_DIALOG
  // - _NET_WM_WINDOW_TYPE_DOCK
  // - _NET_WM_WINDOW_TYPE_DESKTOP
  // - _NET_WM_WINDOW_TYPE_MENU
  // - _NET_WM_WINDOW_TYPE_TOOLBAR
  // - _NET_WM_WINDOW_TYPE_UTILITY
  // - _NET_WM_WINDOW_TYPE_SPLASHSCREEN
  //
  // It will adjust the presentation for the 1x1 window that we don't
  // care about.  I don't think it tweaks the actual pop-up menu at all.
  //
  // For example, use DIALOG, and it puts the hidden menu in the
  // center of the screen and warps the cursor.  Not useful.
  //
  // Also see https://discourse.gnome.org/t/replacing-gtk-window-set-type-hint-in-gtk4/22599
  Display *dpy = gdk_x11_display_get_xdisplay (gdk_surface_get_display (surface));
  Window xid = gdk_x11_surface_get_xid (surface);
  Atom wm_window_type = XInternAtom (dpy, "_NET_WM_WINDOW_TYPE", False);
  Atom type_popup = XInternAtom (dpy, "_NET_WM_WINDOW_TYPE_DIALOG", False);
  XChangeProperty (dpy, xid, wm_window_type, XA_ATOM, 32, PropModeReplace, (unsigned char *) &type_popup, 1);
#endif
}

/*
  Registering actions is a fold() in-order traversal on the menu
  <item> nodes.  Each menu <item> has the following <attribute>
  elements:

  - Label, for the human reader
  - Action, for hooking into GTK4 (always prefixed with "app.")
  - Target, if and only if this is a radio button.
  - Check, which varies by case.  Radio buttons always have selections;
    a "check" of true tells the program to mark that selection.  Other
    entries have a checkbox slot if the "check" exists at all, and it
    may be true or false.

  We accumulate a dictionary across the fold, mapping XML action names
  (e.g., "app.quit") to GSimpleAction names (e.g., "quit").

  Once we have the final dictionary, we can loop across it connecting
  the signal and adding the action to the GApplication.
*/

static gpointer
collect_item (GMenuModel *model, int idx, gpointer accum)
{
#if 0
  // TRACING
  GMenuAttributeIter *iter = g_menu_model_iterate_item_attributes (model, idx);
  while (g_menu_attribute_iter_next (iter))
    {
      const gchar *name = g_menu_attribute_iter_get_name (iter);
      GVariant *value = g_menu_attribute_iter_get_value (iter);
      gchar *pp_value = g_variant_print (value, TRUE);
      fprintf (stderr, "item %d %s => %s\n", idx, name, pp_value);
      g_free (pp_value);
    }
  fprintf (stderr, "item %d DONE\n", idx);
  g_object_unref (iter);
#endif

  char *label_text = NULL;
  g_menu_model_get_item_attribute (model, idx, G_MENU_ATTRIBUTE_LABEL, "s", &label_text);
  if (! label_text)
    {
      fprintf (stderr, "XML menu item has no label\n");
      goto label_failure;
    }

  char *prefixed_name = NULL;
  if (g_menu_model_get_item_attribute (model, idx, G_MENU_ATTRIBUTE_ACTION, "s", &prefixed_name))
    {
      // The old, rep-based equivalent to this code hand-created the
      // menu widgets.  This allowed the old code to present a disabled
      // menu item, by marking the widget as "not sensitive".  But
      // Sawfish uses that "insensitive" concept for two purposes:
      // disabling a menu item, and sticking a header label on the root
      // menu.
      //
      // The XML format doesn't represent any of this.  But we can get
      // the behavior we want by never connecting the menu item to an
      // action.  Use the special fake namespace "insensitive" to
      // indicate this.
      //
      // Note that the XML format does allow true labels on sections, so
      // we *could* now change the generating code to represent the
      // rootmenu label as first-class.  If we did, it would look
      // something like this:
      //
      // <interface>
      //   <menu id='menu'>
      //     <section>
      //       <attribute name='label'>Sawfish Rootmenu</attribute>
      //       <item>
      //         <attribute name='label'>Foo</attribute>
      //         <attribute name='action'>app.foo</attribute>
      //       </item>
      //       <item>
      //         <attribute name='label'>Foo</attribute>
      //         <attribute name='action'>app.foo</attribute>
      //       </item>
      //     [. . .]
      //     </section>
      //   </menu>
      // </interface>

      if (g_str_has_prefix (prefixed_name, "insensitive."))
	{
          goto prefixed_name_failure;
	}

      if (! g_str_has_prefix (prefixed_name, "app."))
	{
	  fprintf (stderr, "XML menu item \"%s\" has invalid action %s\n", label_text, prefixed_name);
          goto prefixed_name_failure;
	}

      // Note that we need this for hash table lookup, but we don't
      // allocate any storage until it's time to create the
      // GSimpleAction.
      char *action_suffix = prefixed_name + 4;

      char *target_text = NULL;
      g_menu_model_get_item_attribute (model, idx, G_MENU_ATTRIBUTE_TARGET, "s", &target_text);

      char *checked_text = NULL;
      g_menu_model_get_item_attribute (model, idx, "checked", "s", &checked_text);

      if (target_text)
	{
	  GSimpleAction *action = G_SIMPLE_ACTION (g_hash_table_lookup (accum, action_suffix));
	  if (! action)
	    {
	      char *action_name = g_strdup (action_suffix);
	      GVariant *state = g_variant_new_string ("");
	      action = g_simple_action_new_stateful (action_name, G_VARIANT_TYPE_STRING, state);
	      g_hash_table_insert (accum, action_name, action);
	    }
	  gboolean is_checked = checked_text && (strcmp (checked_text, "true") == 0);
	  if (is_checked)
	    {
	      g_simple_action_set_state (action, g_variant_new_string (target_text));
	    }
	}
      else if (checked_text)
	{
	  char *action_name = g_strdup (action_suffix);
	  gboolean is_checked = (strcmp (checked_text, "true") == 0);
	  /* Valgrind says that this doesn't leak. */
	  GVariant *state = g_variant_new_boolean (is_checked);
	  GSimpleAction *action = g_simple_action_new_stateful (action_name, NULL, state);
	  g_hash_table_insert (accum, action_name, action);
	}
      else
	{
	  char *action_name = g_strdup (action_suffix);
	  GSimpleAction *action = g_simple_action_new (action_name, NULL);
	  g_hash_table_insert (accum, action_name, action);
	}

      g_free (checked_text);
      g_free (target_text);
    }
  else
    {
      fprintf (stderr, "no action \"%s\"\n", label_text);
    }

  g_free (prefixed_name);

 prefixed_name_failure:
  g_free (label_text);

 label_failure:
  return accum;
}

static gpointer
menu_model_fold (GMenuModel *model, gpointer accum, gpointer (*callback) (GMenuModel *, int, gpointer))
{
  int n = g_menu_model_get_n_items (model);
  for (int i = 0; i < n; ++i)
    {
      if (GMenuModel *submenu = g_menu_model_get_item_link (model, i, G_MENU_LINK_SUBMENU))
	{
	  accum = menu_model_fold (submenu, accum, callback);
	  g_object_unref (submenu);
	}
      else if (GMenuModel *section = g_menu_model_get_item_link (model, i, G_MENU_LINK_SECTION))
	{
	  accum = menu_model_fold (section, accum, callback);
	  g_object_unref (section);
	}
      else
	{
	  accum = (*callback) (model, i, accum);
	}
    }
  return accum;
}

static gboolean
setup_action_for_item (gpointer key, gpointer value, gpointer user_data)
{
  GSimpleAction *action = G_SIMPLE_ACTION (value);
  GApplication *app = user_data;
  g_signal_connect (action, "activate", G_CALLBACK (on_action_activated), app);
  g_action_map_add_action (G_ACTION_MAP (app), G_ACTION (action));
  return true;
}

// For debugging
static void
tracing_g_free (gpointer mem)
{
  fprintf (stderr, "freeing key %s\n", (char *) mem);
  g_free (mem);
}

static void
register_actions_from_menu (GMenuModel *model, GApplication *app)
{
  GHashTable *actions_table = g_hash_table_new_full (g_str_hash,
						     g_str_equal,
#if 0
						     g_free,
#else
						     tracing_g_free,
#endif
						     g_object_unref);

  actions_table = menu_model_fold (model, actions_table, collect_item);
  // We have the collected actions definitions.  Set up the actions as
  // part of a table traversal.
  g_hash_table_foreach_remove (actions_table, setup_action_for_item, app);
  g_hash_table_destroy (actions_table);
}

/*
What a custom CSS file might look like, for this application:

popover.menu {
  background-color: #2d2d2d;
  border: 1px solid #555;
  border-radius: 4px;
  padding: 4px 0;
}

popover.menu modelbutton {
  color: #e0e0e0;
  padding: 6px 16px;
  min-height: 24px;
}

popover.menu modelbutton:hover {
  background-color: #3a6fbf;
  color: #ffffff;
}
*/

static void
dump_css_tree (GtkWidget *widget, int depth)
{
  if (widget)
    {
      for (int i = 0; i < depth; ++i)
	{
	  g_print ("  ");
	}

      /*
         "CSS selectors and combinators" gives an example of an {element,class,ID} tuple.
         (https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Selectors/Selectors_and_combinators)

         p.myClass#myId {
           font-size: 1.5rem;
         }

         But a tree like a generated menu will have default IDs that
         precisely match the type name.  Don't bother printing the ID
         for those generic names.
       */

      g_print ("%s", gtk_widget_get_css_name (widget));
      char **classes = gtk_widget_get_css_classes (widget);

      for (int i = 0; classes && classes[i]; ++i)
	{
	  g_print (".%s", classes[i]);
	}

      const char *type = G_OBJECT_TYPE_NAME (widget);
      const char *name = gtk_widget_get_name (widget);
      if (name && name[0] && strcmp (type, name) != 0)
	{
	  g_print ("#%s", name);
	}
      g_print ("  [%s]\n", type);
      for (GtkWidget * child = gtk_widget_get_first_child (widget);
           child;
           child = gtk_widget_get_next_sibling (child))
	dump_css_tree (child, depth + 1);
    }
}

static void
handleMenu (GtkWidget *parent)
{
  if (! builder_loader)
    {
      fprintf (stderr, "builder_loader not initialized\n");
      g_application_quit (G_APPLICATION (app));
      return;
    }

  GtkBuilder *builder = gtk_builder_new ();
  (*builder_loader) (builder);
  GMenuModel *menu_model = G_MENU_MODEL (gtk_builder_get_object (builder, "menu"));
  if (! menu_model)
    {
      fprintf (stderr, "No <menu id=\"menu\"> found in %s\n", menu_file);
      g_application_quit (G_APPLICATION (app));
      return;
    }

  register_actions_from_menu (menu_model, G_APPLICATION (app));

  popoverWidget = gtk_popover_menu_new_from_model_full (menu_model, GTK_POPOVER_MENU_NESTED);
  gtk_widget_set_parent (popoverWidget, parent);
  gtk_widget_set_halign (popoverWidget, GTK_ALIGN_START);
  gtk_widget_set_valign (popoverWidget, GTK_ALIGN_START);
  g_signal_connect (popoverWidget, "closed", G_CALLBACK (on_popover_closed), app);
#if 0
  // Enable this if you want to dump the CSS tree.
  g_signal_connect(popoverWidget, "show", G_CALLBACK(dump_css_tree), GINT_TO_POINTER(0));
#endif

  GtkPopover *popover = GTK_POPOVER (popoverWidget);
  gtk_popover_set_position (popover, GTK_POS_BOTTOM);
  gtk_popover_set_offset (popover, -HIDDEN_WINDOW_WIDTH, -HIDDEN_WINDOW_HEIGHT);
  gtk_popover_set_has_arrow (popover, FALSE);

  gtk_popover_popup (GTK_POPOVER (popover));

  g_object_unref (builder);
}

static void
on_activate (GApplication *app, gpointer user_data)
{
#if 0
  // Load CSS if we've passed a file along.
  const char *css_file = g_object_get_data (G_OBJECT (app), "css-file");
  if (css_file)
    {
      GtkCssProvider *css = gtk_css_provider_new ();
      gtk_css_provider_load_from_path (css, css_file);
      gtk_style_context_add_provider_for_display (gdk_display_get_default (),
                                                  GTK_STYLE_PROVIDER (css),
                                                  GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
      g_object_unref (css);
    }
#endif

  window = gtk_application_window_new (GTK_APPLICATION (app));
  gtk_window_set_decorated (GTK_WINDOW (window), FALSE);
  gtk_window_set_default_size (GTK_WINDOW (window), HIDDEN_WINDOW_WIDTH, HIDDEN_WINDOW_HEIGHT);

  // https://discourse.gnome.org/t/adjusting-margin-and-padding-of-gtkpopovermenu-items/23014
  // explains how we need need to make any menu a child of a widget with a layout manager.
  // (And windows don't have layout managers.)  A box suffices.
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  gtk_window_set_child (GTK_WINDOW (window), box);

  /*
     We want to set properties "don't put in taskbar" and "don't put in
     pager".  For that we need the X11 window (after "realize") without
     telling anyone about the X11 window (before "show").  Note that
     the gtk_window_present() normally does "realize" itself.

     Quoth the docs on gtk_widget_realize():

     > This function is primarily used in widget implementations, and
     > isn’t very useful otherwise. Many times when you think you might
     > need it, a better approach is to connect to a signal that will
     > be called after the widget is realized automatically, such as
     > GtkWidget::realize."

     But the signal spec seems to allow mixing: realize, map, send
     GtkWidget::realize, send GtkWidget::make.
   */
  gtk_widget_realize (GTK_WIDGET (window));
  set_window_type_popup (GTK_WINDOW (window));
  gtk_window_present (GTK_WINDOW (window));

  handleMenu (box);
}

int
main (int argc, char *argv[])
{
  if (argc != 2)
    {
      fprintf (stderr, "Usage: %s [<menu.xml> | -]\n", argv[0]);
      return 2;
    }

  if (strcmp(argv[1], "-") == 0)
    {
      builder_loader = builder_load_from_stdin;
    }
  else
    {
      menu_file = argv[1];
      builder_loader = builder_load_from_file;
    }

  app = gtk_application_new ("com.local.popupmenu", G_APPLICATION_DEFAULT_FLAGS);

#if 0
  const char *css_file = "my-css-file";
  if (css_file)
    g_object_set_data (G_OBJECT (app), "css-file", (gpointer) css_file);
#endif

  g_signal_connect (app, "activate", G_CALLBACK (on_activate), NULL);

  int status = g_application_run (G_APPLICATION (app), 1, (char *[]) { argv[0] });
  g_object_unref (app);

  return action_fired ? 0 : 1;
}

// That gtk4-x11 package name is the "clean" way of getting both gtk4
// and x11, but someone might need individual gtk4 and x11.
//
// The surrounding Librep code chokes on -std=c2x, so hold things back.
//
// If -Wdeprecated-declarations is on, then the compiler complains about
// GdkX11 being deprecated as of v4.18.  Yes, yes, we get it.

/*

Local Variables:
compile-command: "gcc -o sawfish-menu sawfish-menu.c -Wno-deprecated-declarations -ggdb -std=c17 $(pkg-config --cflags --libs gtk4-x11)";
End:
*/
