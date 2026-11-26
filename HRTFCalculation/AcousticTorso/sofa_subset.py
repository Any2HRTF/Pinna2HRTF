from datetime import datetime, timezone
from pathlib import Path
import numpy as np

def _text(value):
    return value.decode("utf-8") if isinstance(value, bytes) else str(value)


def _copy_subset(source: object, destination: Path, original_indices: np.ndarray,
                 history_line: str) -> None:
    from netCDF4 import Dataset

    with Dataset(destination, "w", format=source.data_model) as dest:
        dest.setncatts({name: source.getncattr(name) for name in source.ncattrs()})
        previous = _text(source.getncattr("History")) if "History" in source.ncattrs() else ""
        dest.setncattr("History", (previous + "\n" + history_line).strip())
        if "DateModified" in source.ncattrs():
            dest.setncattr("DateModified", datetime.now(timezone.utc).isoformat())
        for name, dim in source.dimensions.items():
            size = len(original_indices) if name == "M" else len(dim)
            dest.createDimension(name, None if dim.isunlimited() else size)
        for name, variable in source.variables.items():
            fill = (variable.getncattr("_FillValue")
                    if "_FillValue" in variable.ncattrs() else None)
            filters = variable.filters()
            kwargs: dict[str, object] = {}
            if fill is not None:
                kwargs["fill_value"] = fill
            if filters and filters.get("zlib"):
                kwargs.update(zlib=True,
                              complevel=int(filters.get("complevel", 4)),
                              shuffle=bool(filters.get("shuffle", True)))
            copied = dest.createVariable(name, variable.datatype,
                                         variable.dimensions, **kwargs)
            copied.setncatts({attr: variable.getncattr(attr)
                              for attr in variable.ncattrs() if attr != "_FillValue"})
            values = variable[...]
            for axis, dimension in enumerate(variable.dimensions):
                if dimension == "M":
                    values = np.take(values, original_indices, axis=axis)
            copied[...] = values
