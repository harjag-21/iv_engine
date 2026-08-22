#include <Python.h>
#include "svdpi.h"

static PyObject *pFunc = NULL;
static int       py_ok = 0;

void init_python_env() {
    PyObject *pName   = NULL;
    PyObject *pModule = NULL;

    Py_Initialize();

    /* ---------------------------------------------------------- *
     * Set sys.path to include the directory containing the       *
     * golden model.  XSim CWD during simulation is:              *
     *   <project>/iv_engine.sim/sim_1/behav/xsim/                *
     * The golden model lives in:                                 *
     *   <project>/iv_engine.srcs/sim_1/new/                      *
     * ---------------------------------------------------------- */
    PyRun_SimpleString(
        "import sys, os\n"
        "_base = os.path.abspath('.')\n"
        "# Walk up from .sim/sim_1/behav/xsim to project root\n"
        "_proj = os.path.dirname(os.path.dirname("
        "os.path.dirname(os.path.dirname(_base))))\n"
        "_model_dir = os.path.join(_proj, "
        "'iv_engine.srcs', 'sim_1', 'new')\n"
        "if _model_dir not in sys.path:\n"
        "    sys.path.insert(0, _model_dir)\n"
        "print('[DPI] Python sys.path:', sys.path[:3])\n"
    );

    pName = PyUnicode_DecodeFSDefault("iv_golden_model");
    if (!pName) {
        fprintf(stderr, "[DPI] ERROR: PyUnicode_DecodeFSDefault failed\n");
        return;
    }

    pModule = PyImport_Import(pName);
    Py_DECREF(pName);
    if (!pModule) {
        fprintf(stderr, "[DPI] ERROR: Could not import iv_golden_model\n");
        PyErr_Print();
        return;
    }

    pFunc = PyObject_GetAttrString(pModule, "calculate_full_iv");
    Py_DECREF(pModule);
    if (!pFunc || !PyCallable_Check(pFunc)) {
        fprintf(stderr, "[DPI] ERROR: calculate_full_iv not callable\n");
        Py_XDECREF(pFunc);
        pFunc = NULL;
        return;
    }

    py_ok = 1;
    fprintf(stdout, "[DPI] Golden model loaded successfully\n");
}

int get_golden_iv(int S, int K, int C, int r, int T) {
    int result = 0;
    PyObject *pArgs, *pValue;

    if (!py_ok || !pFunc) {
        fprintf(stderr, "[DPI] WARNING: Python not initialized, returning 0\n");
        return 0;
    }

    pArgs = PyTuple_New(5);
    PyTuple_SetItem(pArgs, 0, PyLong_FromLong(S));
    PyTuple_SetItem(pArgs, 1, PyLong_FromLong(K));
    PyTuple_SetItem(pArgs, 2, PyLong_FromLong(C));
    PyTuple_SetItem(pArgs, 3, PyLong_FromLong(r));
    PyTuple_SetItem(pArgs, 4, PyLong_FromLong(T));

    pValue = PyObject_CallObject(pFunc, pArgs);
    Py_DECREF(pArgs);

    if (pValue != NULL) {
        result = (int)PyLong_AsLong(pValue);
        Py_DECREF(pValue);
    } else {
        fprintf(stderr, "[DPI] ERROR: Python call failed\n");
        PyErr_Print();
    }

    return result;
}

void close_python_env() {
    Py_XDECREF(pFunc);
    pFunc = NULL;
    py_ok = 0;
    Py_Finalize();
    fprintf(stdout, "[DPI] Python environment finalized\n");
}