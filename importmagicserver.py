# -*- coding: utf-8 -*-
"""
importmagic.el server
---------------------

Copyright (c) 2016 Nicolás Salas V.
Licensed under GPL3. See the LICENSE file for details

"""

import sys
from collections import deque

import importmagic
from epc.server import EPCServer

server = EPCServer(('localhost', 0))

# We'll follow a very passive approach. I'm not really familiar with
# neither EPC or cl-lib. So please, don't expect to see a lot of
# quality in this code

index = None


# Since the transformation from Emacs Lisp to Python causes strings to
# be lists of separate characters, we need a function that can provide
# a regular string, which is this one.
def _stringify(input_param):
    return ''.join(input_param)


# Construct the index symbol with top level path specified in the
# argument.
@server.register_function
def build_index(*path):
    global index

    fullpath = sys.path + [_stringify(path)]

    try:
        index = importmagic.SymbolIndex()
        index.build_index(paths=fullpath)
    except:
        print('Failed to build index')
        sys.exit(-1)


# Returns a list of every unresolved symbol in source.
@server.register_function
def get_unresolved_symbols(*source):
    source = _stringify(source)

    scope = importmagic.Scope.from_source(source)
    unres, unref = scope.find_unresolved_and_unreferenced_symbols()

    return list(unres)


# Returns a list of candidates that can import the queried symbol. The
# returned list is ordered by score, meaning that the first element is
# more likely to be appropriate.
@server.register_function
def get_candidates_for_symbol(*symbol):
    symbol = _stringify(symbol)

    candidates = deque([])
    for score, module, variable in index.symbol_scores(symbol):
        if variable is None:
            fmt = 'import {}'.format(str(module))
        else:
            fmt = 'from {} import {}'.format(str(module), str(variable))

        candidates.append(fmt)

    return list(candidates)


# Takes a list where the firest element is the source file as a string
# (assuming the call is from elisp) and the second element is the
# chosen import statement.
@server.register_function
def get_import_statement(*source_and_import):
    source = _stringify(source_and_import[0])
    import_statement = _stringify(source_and_import[1])

    imports = importmagic.importer.Imports(index, source)

    if import_statement.startswith('import '):
        module = import_statement[7:]
        imports.add_import(module)
    else:
        separator = import_statement.find(' import ')
        module = import_statement[5:separator]

        if separator >= 0:
            imports.add_import_from(import_statement[5:separator],
                                    import_statement[(separator + 8):])

    start, end, new_statement = imports.get_update()

    return [start, end, new_statement]


server.print_port()
server.serve_forever()
