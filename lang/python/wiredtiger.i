/*
 * See the file LICENSE for redistribution information.
 *
 * Copyright (c) 2011 WiredTiger, Inc.
 *	All rights reserved.
 *
 * wiredtiger.i
 * 	The SWIG interface file defining the wiredtiger python API.
 *
 */

%module wiredtiger

%pythoncode %{
from packing import pack, unpack
%}

/* Set the input argument to point to a temporary variable */ 
%typemap(in, numinputs=0) WT_CONNECTION ** (WT_CONNECTION *temp = NULL) {
        $1 = &temp;
}
%typemap(in, numinputs=0) WT_SESSION ** (WT_SESSION *temp = NULL) {
        $1 = &temp;
}
%typemap(in, numinputs=0) WT_CURSOR ** (WT_CURSOR *temp = NULL) {
        $1 = &temp;
}

/* Convert 'int *' to an output arg in search_near, wiredtiger_version */
%apply int *OUTPUT { int * };

/* Event handlers are not supported in Python. */
%typemap(in, numinputs=0) WT_EVENT_HANDLER * { $1 = NULL; }

/* Set the return value to the returned connection, session, or cursor */
%typemap(argout) WT_CONNECTION ** {
        $result = SWIG_NewPointerObj(SWIG_as_voidptr(*$1),
             SWIGTYPE_p_wt_connection, 0);
}
%typemap(argout) WT_SESSION ** {
        $result = SWIG_NewPointerObj(SWIG_as_voidptr(*$1),
             SWIGTYPE_p_wt_session, 0);
}

%typemap(argout) WT_CURSOR ** {
        $result = SWIG_NewPointerObj(SWIG_as_voidptr(*$1),
             SWIGTYPE_p_wt_cursor, 0);
        if (*$1 != NULL) {
                (*$1)->flags |= WT_CURSTD_RAW;
                PyObject_SetAttrString($result, "is_column",
                    PyBool_FromLong(strcmp((*$1)->key_format, "r") == 0));
        }
}

/* 64 bit typemaps. */
%typemap(in) uint64_t {
    $1 = PyLong_AsUnsignedLongLong($input);
}
%typemap(out) uint64_t {
    $result = PyLong_FromUnsignedLongLong($1);
}

/* Throw away references after close. */
%define DESTRUCTOR(class, method)
%feature("shadow") class::method %{
    def method(self, *args):
        try:
            return $action(self, *args)
        finally:
            self.this = None
%}
%enddef
DESTRUCTOR(wt_connection, close)
DESTRUCTOR(wt_cursor, close)
DESTRUCTOR(wt_session, close)

/* Don't require empty config strings. */
%typemap(default) const char *config { $1 = NULL; }

/* 
 * Error returns other than WT_NOTFOUND generate an exception.
 * Use our own exception type, in future tailored to the kind
 * of error.
 */
%header %{
static PyObject *wtError;
%}

%init %{
        /*
         * Create an exception type and put it into the _wiredtiger module.
         * First increment the reference count because PyModule_AddObject
         * decrements it.  Then note that "m" is the local variable for the
         * module in the SWIG generated code.  If there is a SWIG variable for
         * this, I haven't found it.
         */
        wtError =
            PyErr_NewException("_wiredtiger.WiredTigerError", NULL, NULL);
        Py_INCREF(wtError);
        PyModule_AddObject(m, "WiredTigerError", wtError);
%}

%pythoncode %{
WiredTigerError = _wiredtiger.WiredTigerError

# Implements the iterable contract
class IterableCursor:
        def __init__(self, cursor):
                self.cursor = cursor

        def __iter__(self):
                return self

        def next(self):
                if self.cursor.next() == WT_NOTFOUND:
                        raise StopIteration
                return self.cursor.get_keys() + self.cursor.get_values()

%}

%typemap(out) int {
        if ($1 != 0 && $1 != WT_NOTFOUND) {
                /* We could use PyErr_SetObject for more complex reporting. */
                SWIG_Python_SetErrorMsg(wtError, wiredtiger_strerror($1));
                SWIG_fail;
        }
        $result = SWIG_From_int((int)($1));
}

/*
 * Extra 'self' elimination.
 * The methods we're wrapping look like this:
 * struct wt_xxx {
 *    int method(WT_XXX *, ...otherargs...);
 * };
 * To SWIG, that is equivalent to:
 *    int method(wt_xxx *self, WT_XXX *, ...otherargs...);
 * and we use consecutive argument matching of typemaps to convert two args to
 * one.
 */
%define SELFHELPER(type)
%typemap(in) (type *self, type *) (void *argp = 0, int res = 0) %{
        res = SWIG_ConvertPtr($input, &argp, $descriptor, $disown | 0);
        if (!SWIG_IsOK(res)) { 
                SWIG_exception_fail(SWIG_ArgError(res),
                    "in method '" "$symname" "', argument " "$argnum"
                    " of type '" "$type" "'");
        }
        $2 = $1 = ($ltype)(argp);
%}
%enddef

SELFHELPER(struct wt_connection)
SELFHELPER(struct wt_session)
SELFHELPER(struct wt_cursor)
     
/* WT_CURSOR customization. */
/* First, replace the varargs get / set methods with Python equivalents. */
%ignore wt_cursor::get_key;
%ignore wt_cursor::set_key;
%ignore wt_cursor::get_value;
%ignore wt_cursor::set_value;

/* SWIG magic to turn Python byte strings into data / size. */
%apply (char *STRING, int LENGTH) { (char *data, int size) };

%extend wt_cursor {
        /* Get / set keys and values */
        void _set_key(char *data, int size) {
                WT_ITEM k;
                k.data = data;
                k.size = (uint32_t)size;
                $self->set_key($self, &k);
        }

        void _set_recno(uint64_t recno) {
                WT_ITEM k;
                uint8_t recno_buf[20];
                if (wiredtiger_struct_pack(recno_buf, sizeof (recno_buf),
                    "r", recno) == 0) {
                        k.data = recno_buf;
                        k.size = (uint32_t)wiredtiger_struct_size("q", recno);
                        $self->set_key($self, &k);
                }
        }

        void _set_value(char *data, int size) {
                WT_ITEM v;
                v.data = data;
                v.size = (uint32_t)size;
                $self->set_value($self, &v);
        }

        PyObject *_get_key() {
                WT_ITEM k;
                int ret = $self->get_key($self, &k);
                if (ret != 0) {
                        SWIG_Python_SetErrorMsg(wtError,
                            wiredtiger_strerror(ret));
                        return (NULL);
                }
                return SWIG_FromCharPtrAndSize(k.data, k.size);
        }

        PyObject *_get_recno() {
                WT_ITEM k;
                uint64_t r;
                int ret = $self->get_key($self, &k);
                if (ret == 0)
                        ret = wiredtiger_struct_unpack(k.data, k.size, "q", &r);
                if (ret != 0) {
                        SWIG_Python_SetErrorMsg(wtError,
                            wiredtiger_strerror(ret));
                        return (NULL);
                }
                return PyLong_FromUnsignedLongLong(r);
        }

        PyObject *_get_value() {
                WT_ITEM v;
                int ret = $self->get_value($self, &v);
                if (ret != 0) {
                        SWIG_Python_SetErrorMsg(wtError,
                            wiredtiger_strerror(ret));
                        return (NULL);
                }
                return SWIG_FromCharPtrAndSize(v.data, v.size);
        }

%pythoncode %{
        def get_key(self):
            return self.get_keys()[0]

        def get_keys(self):
            if self.is_column:
                return [self._get_recno(),]
            else:
                return unpack(self.key_format, self._get_key())

        def get_value(self):
                return self.get_values()[0]

        def get_values(self):
                return unpack(self.value_format, self._get_value())

        def set_key(self, *args):
            if self.is_column:
                self._set_recno(args[0])
            else:
                # Keep the Python string pinned
                self._key = pack(self.key_format, *args)
                self._set_key(self._key)

        def set_value(self, *args):
                # Keep the Python string pinned
                self._value = pack(self.value_format, *args)
                self._set_value(self._value)

        def __iter__(self):
                if not hasattr(self, '_iterable'):
                        self._iterable = IterableCursor(self)
                return self._iterable

        # De-position the cursor so the next iteration starts from the beginning
        def reset(self):
                self.last()
                self.next()
%}
};

/* Remove / rename parts of the C API that we don't want in Python. */
%immutable wt_cursor::session;
%immutable wt_cursor::key_format;
%immutable wt_cursor::value_format;
%immutable wt_session::connection;

%ignore wt_buf;
%ignore wt_collator;
%ignore wt_compressor;
%ignore wt_connection::add_collator;
%ignore wt_cursor_type;
%ignore wt_connection::add_cursor_type;
%ignore wt_event_handler;
%ignore wt_extractor;
%ignore wt_connection::add_extractor;
%ignore wt_item;

%ignore wiredtiger_struct_pack;
%ignore wiredtiger_struct_packv;
%ignore wiredtiger_struct_size;
%ignore wiredtiger_struct_sizev;
%ignore wiredtiger_struct_unpack;
%ignore wiredtiger_struct_unpackv;

%ignore wiredtiger_extension_init;

%rename(Cursor) wt_cursor;
%rename(Session) wt_session;
%rename(Connection) wt_connection;

%include "wiredtiger.h"
