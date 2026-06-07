#ifndef WR_STORAGE_SERVICE_H
#define WR_STORAGE_SERVICE_H

/* Start the worker backing the Storage GATT service. The GATT service itself
 * is statically registered; this only enables LIST/FETCH command handling. */
void wr_storage_service_start(void);

#endif /* WR_STORAGE_SERVICE_H */
