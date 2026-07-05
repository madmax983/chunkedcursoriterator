import { LightningElement, track, api } from 'lwc';
import startSession from '@salesforce/apex/CursorDatatableController.startSession';
import fetchNextChunk from '@salesforce/apex/CursorDatatableController.fetchNextChunk';

export default class CursorDatatable extends LightningElement {
    @api query = 'SELECT Id, Name, Industry, Phone FROM Account ORDER BY Name';
    @api sObjectType = 'Account';
    @api chunkSize = 50;

    @track records = [];
    @track columns = [
        { label: 'Name', fieldName: 'Name', type: 'text' },
        { label: 'Industry', fieldName: 'Industry', type: 'text' },
        { label: 'Phone', fieldName: 'Phone', type: 'phone' }
    ];

    @track isLoading = false;
    iteratorState;
    hasMore = false;
    totalRecords = 0;

    connectedCallback() {
        this.loadInitialData();
    }

    async loadInitialData() {
        this.isLoading = true;
        try {
            const result = await startSession({
                query: this.query,
                chunkSize: this.chunkSize,
                sObjectType: this.sObjectType
            });
            this.records = result.records;
            this.iteratorState = result.iteratorState;
            this.hasMore = result.hasMore;
            this.totalRecords = result.totalRecords;
        } catch (error) {
            console.error('Error starting cursor session:', error);
        } finally {
            this.isLoading = false;
        }
    }

    async handleLoadMore(event) {
        if (!this.hasMore) {
            event.target.enableInfiniteLoading = false;
            return;
        }

        this.isLoading = true;
        try {
            const result = await fetchNextChunk({
                iteratorState: this.iteratorState
            });
            this.records = [...this.records, ...result.records];
            this.iteratorState = result.iteratorState;
            this.hasMore = result.hasMore;
        } catch (error) {
            console.error('Error fetching next cursor chunk:', error);
        } finally {
            this.isLoading = false;
        }
    }
}
