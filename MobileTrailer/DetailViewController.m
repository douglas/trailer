
@implementation DetailViewController

static DetailViewController *_detail_shared_ref;

+ (DetailViewController *)shared
{
	return _detail_shared_ref;
}

#pragma mark - Managing the detail item

- (void)setDetailItem:(id)newDetailItem
{
    if (_detailItem != newDetailItem || self.web.hidden)
	{
        _detailItem = newDetailItem;
        [self configureView];
    }
}

- (void)configureView
{
	if (self.detailItem)
	{
		DLog(@"will load: %@",self.detailItem.absoluteString);
		[self.web loadRequest:[NSURLRequest requestWithURL:self.detailItem]];
		self.statusLabel.text = @"";
		self.statusLabel.hidden = YES;
	}
	else
	{
		[self setEmpty];
	}
}

- (void)setEmpty
{
	self.statusLabel.textColor = [COLOR_CLASS lightGrayColor];
	self.statusLabel.text = @"Please select a Pull Request from the list on the left, or select 'Settings' to change your repository selection.\n\n(You may have to login to GitHub the first time you visit a page)";
	self.statusLabel.hidden = NO;
	self.navigationItem.rightBarButtonItem.enabled = NO;
	self.title = nil;
	self.web.hidden = YES;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
	_detail_shared_ref = self;
	[self configureView];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection
{
	[super traitCollectionDidChange:previousTraitCollection];

	self.navigationItem.leftBarButtonItem = (self.traitCollection.horizontalSizeClass==UIUserInterfaceSizeClassCompact) ? nil : self.splitViewController.displayModeButtonItem;
}

- (BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)navigationType
{
	[NSURLConnection connectionWithRequest:request delegate:self];
	return YES;
}

- (void) connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
	NSInteger code = ((NSHTTPURLResponse*)response).statusCode;
	if(code==404)
	{
		[[[UIAlertView alloc] initWithTitle:@"Not Found"
									message:[NSString stringWithFormat:@"\nPlease ensure you are logged in with the '%@' account on GitHub\n\nIf you are using two-factor auth: There is a bug between Github and iOS which may cause your login to fail.  If it happens, temporarily disable two-factor auth and log in from here, then re-enable it afterwards.  You will only need to do this once.",settings.localUser]
								   delegate:nil
						  cancelButtonTitle:@"OK"
						  otherButtonTitles:nil] show];
	}
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	if(self.web.isLoading)
		[self.spinner startAnimating];
	else
		[self.spinner stopAnimating];
}

- (void)webViewDidStartLoad:(UIWebView *)webView
{
	[self.spinner startAnimating];
	self.statusLabel.hidden = YES;
	self.web.hidden = YES;
    self.tryAgainButton.hidden = YES;
	self.title = @"Loading...";
}

- (void)webViewDidFinishLoad:(UIWebView *)webView
{
	[self.spinner stopAnimating];
	self.statusLabel.hidden = YES;
	self.web.hidden = NO;
    self.tryAgainButton.hidden = YES;
	self.navigationItem.rightBarButtonItem.enabled = YES;
	self.title = [self.web stringByEvaluatingJavaScriptFromString:@"document.title"];
}

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error
{
	[self.spinner stopAnimating];
	self.statusLabel.textColor = [COLOR_CLASS redColor];
	self.statusLabel.text = [NSString stringWithFormat:@"There was an error loading this pull request page: %@",error.localizedDescription];
	self.statusLabel.hidden = NO;
	self.web.hidden = YES;
    self.tryAgainButton.hidden = NO;
	self.title = @"Error";
}

- (IBAction)ipadShareButtonSelected:(UIBarButtonItem *)sender
{
	[app shareFromView:self buttonItem:sender url:self.web.request.URL];
}

- (IBAction)iPadTryAgain:(UIButton *)sender
{
    self.detailItem = self.detailItem;
}

@end