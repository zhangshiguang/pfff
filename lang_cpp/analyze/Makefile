TOP=../..
##############################################################################
# Variables
##############################################################################
TARGET=lib

SRC= flag_analyze_cpp.ml \
     builtins_cpp.ml \
     highlight_cpp.ml \
     error_cpp.ml \
     check_variables_cpp.ml \
     database_light_cpp.ml \
     test_analyze_cpp.ml

-include $(TOP)/Makefile.config

#ifeq ($(FEATURES_PCRE), 1)
#PCRECMA=pcre.cma
#PCREINCLUDE= +pcre
#PCREINCLUDE=$(TOP)/
#endif

SYSLIBS= str.cma unix.cma $(PCRECMA)
LIBS=$(TOP)/commons/lib.cma \
     $(TOP)/h_program-lang/lib.cma \
     $(TOP)/h_version-control/lib.cma \
     ../parsing/lib.cma \

#database \
# dynamic_analysis static_analysis \
# qa_test qa_code \

INCLUDEDIRS= $(TOP)/commons \
   $(TOP)/commons/ocollection $(TOP)/commons/ocamlextra \
   $(TOP)/external/ \
   $(TOP)/h_program-lang $(TOP)/h_version-control  \
   $(TOP)/globals \
   ../parsing \

#   $(TOP)/analyze_php/basic \
#   $(TOP)/analyze_php/foundation \
#   $(TOP)/analyze_php/database \
#   $(TOP)/analyze_php/checker \
#   $(TOP)/analyze_php/annotaters \
#   $(TOP)/analyze_php/tools \
#   $(TOP)/analyze_php/typing \
#   $(TOP)/analyze_php/static_analysis \
#   $(TOP)/analyze_php/dynamic_analysis \
#   $(TOP)/analyze_php/qa_test \

#   $(PCREINCLUDE) $(JANEINCLUDE)
#$(TOP)/matcher_php
#$(TOP)/parsing-comments \
#$(TOP)/smpl \

##############################################################################
# Generic variables
##############################################################################
-include $(TOP)/Makefile.common


##############################################################################
# Top rules
##############################################################################
all:: rec $(TARGET).cma
all.opt:: rec.opt $(TARGET).cmxa

rec:
	set -e; for i in $(MAKESUBDIRS); do $(MAKE) -C $$i all || exit 1; done 

rec.opt:
	set -e; for i in $(MAKESUBDIRS); do $(MAKE) -C $$i all.opt || exit 1; done 

clean::
	set -e; for i in $(MAKESUBDIRS); do $(MAKE) -C $$i clean; done 
depend::
	set -e; for i in $(MAKESUBDIRS); do $(MAKE) -C $$i depend; done 


$(TARGET).cma: $(OBJS)
	$(OCAMLC) -a -o $(TARGET).cma $(OBJS)

$(TARGET).cmxa: $(OPTOBJS) $(LIBS:.cma=.cmxa)
	$(OCAMLOPT) -a -o $(TARGET).cmxa $(OPTOBJS)

$(TARGET).top: $(OBJS) $(LIBS)
	$(OCAMLMKTOP) -o $(TARGET).top $(SYSLIBS) $(LIBS) $(OBJS)

clean::
	rm -f $(TARGET).top


##############################################################################
# Literate Programming rules
##############################################################################

